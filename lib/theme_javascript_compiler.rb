# frozen_string_literal: true

class ThemeJavascriptCompiler
  COLOCATED_CONNECTOR_REGEX =
    %r{\A(?<prefix>.*/?)connectors/(?<outlet>[^/]+)/(?<name>[^/\.]+)\.(?<extension>.+)\z}

  class CompileError < StandardError
  end

  @@terser_disabled = false
  def self.disable_terser!
    raise "Tests only" if !Rails.env.test?
    @@terser_disabled = true
  end

  def self.enable_terser!
    raise "Tests only" if !Rails.env.test?
    @@terser_disabled = false
  end

  def initialize(theme_id, theme_name, settings = {}, minify: true)
    @theme_id = theme_id
    @input_tree = {}
    @theme_name = theme_name
    @minify = minify
    @settings = settings
  end

  def compile!
    if !@compiled
      @compiled = true
      @input_tree.freeze

      output_tree = compile_tree!

      output =
        if !output_tree.present?
          { "code" => "" }
        elsif @@terser_disabled || !@minify
          { "code" => output_tree.map { |filename, source| source }.join("") }
        else
          DiscourseJsProcessor::Transpiler.new.terser(output_tree, terser_config)
        end

      @content = output["code"]
      @source_map = output["map"]
    end
    [@content, @source_map]
  rescue DiscourseJsProcessor::TranspileError => e
    message = "[THEME #{@theme_id} '#{@theme_name}'] Compile error: #{e.message}"
    @content = "console.error(#{message.to_json});\n"
    [@content, @source_map]
  end

  def terser_config
    # Based on https://github.com/ember-cli/ember-cli-terser/blob/28df3d90a5/index.js#L12-L26
    {
      sourceMap: {
        includeSources: true,
        root: "theme-#{@theme_id}/",
      },
      compress: {
        negate_iife: false,
        sequences: 30,
        drop_debugger: false,
      },
      output: {
        semicolons: false,
      },
    }
  end

  def content
    compile!
    @content
  end

  def source_map
    compile!
    @source_map
  end

  def append_tree(tree)
    @input_tree.merge!(tree)
  end

  private

  def compile_tree!
    input_tree = @input_tree.dup

    # Replace legacy extensions
    input_tree.transform_keys! do |filename|
      if filename.ends_with? ".js.es6"
        filename.sub(/\.js\.es6\z/, ".js")
      else
        filename
      end
    end

    # Some themes are colocating connector JS under `/connectors`. Move template to /templates to avoid module name clash
    input_tree.transform_keys! do |filename|
      match = COLOCATED_CONNECTOR_REGEX.match(filename)
      next filename if !match

      is_template = match[:extension] == "hbs"
      is_in_templates_directory = match[:prefix].split("/").last == "templates"

      if is_template && !is_in_templates_directory
        "#{match[:prefix]}templates/connectors/#{match[:outlet]}/#{match[:name]}.#{match[:extension]}"
      elsif !is_template && is_in_templates_directory
        "#{match[:prefix].chomp("templates/")}connectors/#{match[:outlet]}/#{match[:name]}.#{match[:extension]}"
      else
        filename
      end
    end

    # Handle colocated components
    input_tree.dup.each_pair do |filename, content|
      is_component_template =
        filename.end_with?(".hbs") &&
          filename.start_with?("discourse/components/", "admin/components/")
      next if !is_component_template
      template_contents = content

      hbs_invocation_options = { moduleName: filename, parseOptions: { srcName: filename } }
      hbs_invocation = "hbs(#{template_contents.to_json}, #{hbs_invocation_options.to_json})"

      prefix = <<~JS
        import { hbs } from 'ember-cli-htmlbars';
        const __COLOCATED_TEMPLATE__ = #{hbs_invocation};
      JS

      js_filename = filename.sub(/\.hbs\z/, ".js")
      js_contents = input_tree[js_filename] # May be nil for template-only component
      if js_contents && !js_contents.include?("export default")
        message =
          "#{filename} does not contain a `default export`. Did you forget to export the component class?"
        js_contents += "throw new Error(#{message.to_json});"
      end

      if js_contents.nil?
        # No backing class, use template-only
        js_contents = <<~JS
          import templateOnly from '@ember/component/template-only';
          export default templateOnly();
        JS
      end

      js_contents = prefix + js_contents

      input_tree[js_filename] = js_contents
      input_tree.delete(filename)
    end

    output_tree = {}

    register_settings(@settings, tree: output_tree)

    # Transpile and write to output
    input_tree.each_pair do |filename, content|
      module_name, extension = filename.split(".", 2)

      if extension == "js" || extension == "gjs"
        append_module(content, module_name, extension, tree: output_tree)
      elsif extension == "hbs"
        append_ember_template(module_name, content, tree: output_tree)
      else
        append_js_error(
          filename,
          "unknown file extension '#{extension}' (#{filename})",
          tree: output_tree,
        )
      end
    rescue CompileError => e
      append_js_error filename, "#{e.message} (#{filename})", tree: output_tree
    end

    output_tree
  end

  def append_ember_template(name, hbs_template, tree:)
    module_name = name
    module_name = "/#{module_name}" if !module_name.start_with?("/")
    module_name = "discourse/theme-#{@theme_id}#{module_name}"

    # Mimics the ember-cli implementation
    # https://github.com/ember-cli/ember-cli-htmlbars/blob/d5aa14b3/lib/template-compiler-plugin.js#L18-L26
    script = <<~JS
      import { hbs } from 'ember-cli-htmlbars';
      export default hbs(#{hbs_template.to_json}, { moduleName: #{module_name.to_json} });
    JS

    template_module = DiscourseJsProcessor.transpile(script, "", module_name, theme_id: @theme_id)
    tree["#{name}.js"] = <<~JS
      if ('define' in window) {
      #{template_module}
      }
    JS
  rescue MiniRacer::RuntimeError, DiscourseJsProcessor::TranspileError => ex
    raise CompileError.new ex.message
  end

  def append_raw_script(filename, script, tree:)
    tree[filename] = script + "\n"
  end

  def append_module(script, name, extension, include_variables: true, tree:)
    original_filename = name
    name = "discourse/theme-#{@theme_id}/#{name}"

    script = "#{theme_settings}#{script}" if include_variables
    transpiler = DiscourseJsProcessor::Transpiler.new

    tree["#{original_filename}.#{extension}"] = <<~JS
      if ('define' in window) {
      #{transpiler.perform(script, "", name, theme_id: @theme_id, extension: extension).strip}
      }
    JS
  rescue MiniRacer::RuntimeError, DiscourseJsProcessor::TranspileError => ex
    raise CompileError.new ex.message
  end

  def append_js_error(filename, message, tree:)
    message = "[THEME #{@theme_id} '#{@theme_name}'] Compile error: #{message}"
    append_raw_script filename, "console.error(#{message.to_json});", tree:
  end

  def register_settings(settings_hash, tree:)
    append_raw_script("settings.js", <<~JS, tree:)
      (function() {
        if ('require' in window) {
          require("discourse/lib/theme-settings-store").registerSettings(#{@theme_id}, #{settings_hash.to_json});
        }
      })();
    JS
  end

  def theme_settings
    <<~JS
      const settings = require("discourse/lib/theme-settings-store")
        .getObjectForTheme(#{@theme_id});
      const themePrefix = (key) => `theme_translations.#{@theme_id}.${key}`;
    JS
  end
end

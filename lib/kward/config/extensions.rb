# Configuration extensions behavior.
module Kward
  module ConfigFiles
    module Extensions
      extend self

      # Lists configured skills discovered under the config directory.
      #
      # @return [Array<Skill>] skill metadata available to the model
      def skills(workspace_root: Dir.pwd, warning_sink: nil, project_skill_paths: nil)
        skills_registry(workspace_root: workspace_root, warning_sink: warning_sink, project_skill_paths: project_skill_paths).skills
      end

      def project_skill_candidates(workspace_root: Dir.pwd, warning_sink: nil)
        skills_registry(workspace_root: workspace_root, warning_sink: warning_sink).project_skill_candidates
      end

      # @return [String] trusted user plugin directory
      def plugin_dir
        File.expand_path("~/.kward/plugins")
      end

      # Finds trusted plugin files and package entrypoints.
      #
      # Plugins are intentionally loaded only from `~/.kward/plugins`, not from a
      # workspace or custom `KWARD_CONFIG_PATH` directory.
      #
      # @return [Array<String>] sorted plugin file paths
      def plugin_paths(warning_sink: nil)
        plugins_root = plugin_dir
        return [] unless Dir.exist?(plugins_root)

        paths = Dir.glob(File.join(plugins_root, "*.rb"))
        paths.concat(Dir.glob(File.join(plugins_root, "*", "plugin.rb")))
        paths.sort
      rescue StandardError => e
        emit_warning("Warning: skipping Kward plugins in #{plugins_root}: #{e.message}", warning_sink: warning_sink)
        []
      end

      # Lists prompt templates exposed as slash commands.
      #
      # @param reserved_commands [Array<String>] command names unavailable to templates
      # @return [Array<PromptTemplate>] prompt template metadata and bodies
      def prompt_templates(reserved_commands: [])
        prompt_template_registry.prompt_templates(reserved_commands: reserved_commands)
      end

      # Reads a skill file by skill name and optional relative path.
      #
      # @param name [String] configured skill name
      # @param relative_path [String, nil] path inside the skill directory
      # @return [String] file contents or an error string
      def read_skill_file(name, relative_path = nil, workspace_root: Dir.pwd)
        skills_registry(workspace_root: workspace_root).read_skill_file(name, relative_path)
      end

      def skills_registry(workspace_root: Dir.pwd, warning_sink: nil, project_skill_paths: nil)
        Skills::Registry.new(
          config_dir: config_dir,
          workspace_root: workspace_root,
          project_skills_trusted: project_skills_trusted?,
          skill_class: Skill,
          max_file_bytes: MAX_SKILL_FILE_BYTES,
          markdown_parser: ->(path) { Frontmatter.markdown_parts(path, lenient: true) },
          inside_directory: method(:inside_directory?),
          warning_sink: warning_sink || @warning_sink,
          project_skill_paths: project_skill_paths
        )
      end

      def prompt_template_registry
        ::Kward::Prompts::Templates.new(
          config_dir: config_dir,
          template_class: PromptTemplate,
          markdown_parser: ->(path) { Frontmatter.markdown_parts(path) },
          warning_sink: @warning_sink
        )
      end

      def emit_warning(message, warning_sink: nil)
        sink = warning_sink || @warning_sink
        sink ? sink.call(message) : warn(message)
      end

      def inside_directory?(path, base)
        PathGuard.inside?(path, base)
      end

      def presence(value)
        text = value.to_s
        text.empty? ? nil : text
      end
    end
  end
end

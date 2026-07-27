require "pathname"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Skill discovery and metadata parsing from configured skill folders.
  module Skills
    # Discovers Agent Skills and reads their bounded instruction resources.
    #
    # Project sources are included only when the caller marks them trusted. If
    # duplicate skill names exist, the first source in documented precedence
    # order wins.
    #
    # @api public
    class Registry
      SkillSource = Struct.new(:root, :label, :scope, :precedence, keyword_init: true)

      def initialize(config_dir:, workspace_root:, project_skills_trusted:, skill_class:, max_file_bytes:, markdown_parser:, inside_directory:, warning_sink: nil)
        @config_dir = config_dir
        @workspace_root = workspace_root
        @project_skills_trusted = project_skills_trusted
        @skill_class = skill_class
        @max_file_bytes = max_file_bytes
        @markdown_parser = markdown_parser
        @inside_directory = inside_directory
        @warning_sink = warning_sink
      end

      # Returns discovered, validated skills in precedence order.
      #
      # @return [Array<ConfigFiles::Skill>]
      # @api public
      def skills
        seen = {}
        skill_sources.flat_map do |source|
          scan_source(source).filter_map do |path|
            skill = parse_skill(path)
            next unless skill

            if seen[skill.name]
              emit_warning "Warning: skipping duplicate Kward skill #{skill.name.inspect}: #{path}"
              next
            end

            seen[skill.name] = true
            skill
          end
        end
      rescue StandardError => e
        emit_warning "Warning: skipping Kward skills: #{e.message}"
        []
      end

      # Reads a skill's main instructions or a bounded relative resource.
      #
      # Absolute paths, paths escaping the skill folder, missing files, and files
      # above the configured size limit return user-facing error strings.
      #
      # @param name [String, #to_s] discovered skill name
      # @param relative_path [String, nil] file relative to the skill directory;
      #   defaults to `SKILL.md`
      # @return [String] skill content or an error message
      # @api public
      def read_skill_file(name, relative_path = nil)
        skill = skills.find { |candidate| candidate.name == name.to_s }
        return "Error: unknown skill: #{name}" unless skill

        path = relative_path.to_s.empty? ? "SKILL.md" : relative_path.to_s
        return "Error: skill path must be relative" if Pathname.new(path).absolute?

        base = File.realpath(skill.folder)
        target = File.expand_path(path, base)
        real_target = File.realpath(target)
        unless @inside_directory.call(real_target, base)
          return "Error: skill path outside skill folder: #{path}"
        end
        return "Error: skill path is not a file: #{path}" unless File.file?(real_target)

        size = File.size(real_target)
        return "Error: skill file too large: #{path} (#{size} bytes)" if size > @max_file_bytes

        content = File.read(real_target)
        relative_path.to_s.empty? ? skill_content(skill, content) : content
      rescue Errno::ENOENT
        "Error: skill file not found: #{path}"
      rescue StandardError => e
        "Error: could not read skill file #{path}: #{e.message}"
      end

      private

      def skill_sources
        [
          SkillSource.new(root: File.join(@workspace_root, ".kward", "skills"), label: "project Kward skills", scope: :project, precedence: 0),
          SkillSource.new(root: File.join(@workspace_root, ".agents", "skills"), label: "project Agent Skills", scope: :project, precedence: 1),
          SkillSource.new(root: File.join(@config_dir, "skills"), label: "user Kward skills", scope: :user, precedence: 2),
          SkillSource.new(root: File.expand_path("~/.agents/skills"), label: "user Agent Skills", scope: :user, precedence: 3)
        ]
      end

      def scan_source(source)
        return [] unless Dir.exist?(source.root)
        if source.scope == :project && !@project_skills_trusted
          emit_warning "Warning: skipping #{source.label} in #{source.root}: project skills are not trusted"
          return []
        end

        Dir.glob(File.join(source.root, "*", "SKILL.md")).sort
      rescue StandardError => e
        emit_warning "Warning: skipping #{source.label} in #{source.root}: #{e.message}"
        []
      end

      def skill_content(skill, content)
        lines = [
          %(<skill_content name="#{xml_escape(skill.name)}">),
          content,
          "",
          "Skill directory: #{File.realpath(skill.folder)}",
          "Relative paths in this skill are relative to the skill directory."
        ]
        resources = skill_resources(skill.folder)
        unless resources.empty?
          lines << ""
          lines << "<skill_resources>"
          resources.each { |path| lines << "  <file>#{xml_escape(path)}</file>" }
          lines << "</skill_resources>"
        end
        lines << "</skill_content>"
        lines.join("\n")
      end

      def skill_resources(folder)
        roots = %w[scripts references assets].map { |name| File.join(folder, name) }.select { |path| Dir.exist?(path) }
        resources = roots.flat_map do |root|
          Dir.glob(File.join(root, "**", "*"))
        end.select { |path| File.file?(path) }.sort.first(200)
        base = Pathname.new(folder)
        resources.map { |path| Pathname.new(path).relative_path_from(base).to_s }
      rescue StandardError
        []
      end

      def xml_escape(text)
        text.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;").gsub('"', "&quot;")
      end

      def parse_skill(path)
        frontmatter, = @markdown_parser.call(path)
        name = frontmatter.fetch("name", "").to_s.strip
        description = frontmatter.fetch("description", "").to_s.strip
        return warn_skip(path, "missing name") if name.empty?
        return warn_skip(path, "missing description") if description.empty?
        return warn_skip(path, "description exceeds 1024 characters") if description.length > 1024

        emit_warning "Warning: Kward skill #{path}: name does not match parent directory" if name != File.basename(File.dirname(path))
        emit_warning "Warning: Kward skill #{path}: name exceeds 64 characters" if name.length > 64
        emit_warning "Warning: Kward skill #{path}: name contains invalid characters" unless valid_name?(name)

        compatibility = optional_text(frontmatter["compatibility"])
        emit_warning "Warning: Kward skill #{path}: compatibility exceeds 500 characters" if compatibility && compatibility.length > 500

        @skill_class.new(
          name: name,
          description: description,
          folder: File.dirname(path),
          path: path,
          license: optional_text(frontmatter["license"]),
          compatibility: compatibility,
          metadata: frontmatter["metadata"].is_a?(Hash) ? frontmatter["metadata"] : {},
          allowed_tools: optional_text(frontmatter["allowed-tools"])
        )
      rescue StandardError => e
        emit_warning "Warning: skipping Kward skill #{path}: #{e.message}"
        nil
      end

      def valid_name?(name)
        name.match?(/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/)
      end

      def optional_text(value)
        text = value.to_s.strip
        text.empty? ? nil : text
      end

      def warn_skip(path, reason)
        emit_warning "Warning: skipping Kward skill #{path}: #{reason}"
        nil
      end

      def emit_warning(message)
        @warning_sink ? @warning_sink.call(message) : warn(message)
      end
    end
  end
end

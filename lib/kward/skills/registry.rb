require "pathname"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Skill discovery and metadata parsing from configured skill folders.
  module Skills
    # Parsed skill metadata and instruction path.
    class Registry
      SkillSource = Struct.new(:root, :label, :scope, :precedence, keyword_init: true)

      def initialize(config_dir:, workspace_root:, project_skills_trusted:, skill_class:, max_file_bytes:, markdown_parser:, inside_directory:)
        @config_dir = config_dir
        @workspace_root = workspace_root
        @project_skills_trusted = project_skills_trusted
        @skill_class = skill_class
        @max_file_bytes = max_file_bytes
        @markdown_parser = markdown_parser
        @inside_directory = inside_directory
      end

      def skills
        seen = {}
        skill_sources.flat_map do |source|
          scan_source(source).filter_map do |path|
            skill = parse_skill(path)
            next unless skill

            if seen[skill.name]
              warn "Warning: skipping duplicate Kward skill #{skill.name.inspect}: #{path}"
              next
            end

            seen[skill.name] = true
            skill
          end
        end
      rescue StandardError => e
        warn "Warning: skipping Kward skills: #{e.message}"
        []
      end

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

        File.read(real_target)
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
          warn "Warning: skipping #{source.label} in #{source.root}: project skills are not trusted"
          return []
        end

        Dir.glob(File.join(source.root, "*", "SKILL.md")).sort
      rescue StandardError => e
        warn "Warning: skipping #{source.label} in #{source.root}: #{e.message}"
        []
      end

      def parse_skill(path)
        frontmatter, = @markdown_parser.call(path)
        name = frontmatter.fetch("name", "").to_s.strip
        name = File.basename(File.dirname(path)) if name.empty?
        description = frontmatter.fetch("description", "").to_s.strip

        @skill_class.new(name: name, description: description, folder: File.dirname(path), path: path)
      rescue StandardError => e
        warn "Warning: skipping Kward skill #{path}: #{e.message}"
        nil
      end
    end
  end
end

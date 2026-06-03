require "pathname"
require "yaml"

module Kward
  module ConfigFiles
    MAX_SKILL_FILE_BYTES = 100_000

    Skill = Struct.new(:name, :description, :folder, :path, keyword_init: true)

    module_function

    def config_dir
      config_path = ENV["KWARD_CONFIG_PATH"]
      return File.expand_path(File.dirname(config_path)) if config_path && !config_path.empty?

      File.expand_path("~/.kward")
    end

    def agents_prompt
      path = File.join(config_dir, "AGENTS.md")
      return nil unless File.exist?(path)

      File.read(path)
    rescue StandardError => e
      warn "Warning: skipping Kward prompt file #{path}: #{e.message}"
      nil
    end

    def skills
      skills_root = File.join(config_dir, "skills")
      return [] unless Dir.exist?(skills_root)

      seen = {}
      Dir.glob(File.join(skills_root, "*", "SKILL.md")).sort.filter_map do |path|
        skill = parse_skill(path)
        next unless skill

        if seen[skill.name]
          warn "Warning: skipping duplicate Kward skill #{skill.name.inspect}: #{path}"
          next
        end

        seen[skill.name] = true
        skill
      end
    rescue StandardError => e
      warn "Warning: skipping Kward skills in #{skills_root}: #{e.message}"
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
      unless inside_directory?(real_target, base)
        return "Error: skill path outside skill folder: #{path}"
      end
      return "Error: skill path is not a file: #{path}" unless File.file?(real_target)

      size = File.size(real_target)
      return "Error: skill file too large: #{path} (#{size} bytes)" if size > MAX_SKILL_FILE_BYTES

      File.read(real_target)
    rescue Errno::ENOENT
      "Error: skill file not found: #{path}"
    rescue StandardError => e
      "Error: could not read skill file #{path}: #{e.message}"
    end

    def parse_skill(path)
      frontmatter = frontmatter_for(path)
      name = frontmatter.fetch("name", "").to_s.strip
      name = File.basename(File.dirname(path)) if name.empty?
      description = frontmatter.fetch("description", "").to_s.strip

      Skill.new(name: name, description: description, folder: File.dirname(path), path: path)
    rescue StandardError => e
      warn "Warning: skipping Kward skill #{path}: #{e.message}"
      nil
    end

    def frontmatter_for(path)
      content = File.read(path)
      return {} unless content.start_with?("---\n", "---\r\n")

      _opening, rest = content.split(/\A---\r?\n/, 2)
      yaml_text, = rest.to_s.split(/\r?\n---\r?\n/, 2)
      return {} if yaml_text.nil? || yaml_text.empty?

      data = YAML.safe_load(yaml_text, permitted_classes: [], aliases: false)
      data.is_a?(Hash) ? data.transform_keys(&:to_s) : {}
    end

    def inside_directory?(path, base)
      path == base || path.start_with?(base + File::SEPARATOR)
    end
  end
end

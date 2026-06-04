require "fileutils"
require "json"
require "pathname"
require "yaml"

module Kward
  module ConfigFiles
    MAX_SKILL_FILE_BYTES = 100_000
    DEFAULT_OVERLAY_SETTINGS = { "alignment" => "center", "width" => "capped" }.freeze
    OVERLAY_ALIGNMENTS = %w[left center right].freeze
    OVERLAY_WIDTHS = %w[capped maximum].freeze

    Skill = Struct.new(:name, :description, :folder, :path, keyword_init: true)
    PromptTemplate = Struct.new(:command, :description, :argument_hint, :body, :path, keyword_init: true) do
      def expand(arguments)
        body.gsub("$ARGUMENTS", arguments.to_s)
      end
    end

    module_function

    def config_dir
      config_path = ENV["KWARD_CONFIG_PATH"]
      return File.expand_path(File.dirname(config_path)) if config_path && !config_path.empty?

      File.expand_path("~/.kward")
    end

    def config_path
      File.expand_path(ENV["KWARD_CONFIG_PATH"] || File.join(config_dir, "config.json"))
    end

    def read_config
      path = config_path
      return {} unless File.exist?(path)

      JSON.parse(File.read(path))
    rescue JSON::ParserError
      raise "Invalid Kward config JSON: #{path}"
    end

    def write_config(config)
      path = config_path
      FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
      File.open(path, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |file|
        file.write(JSON.pretty_generate(config))
        file.write("\n")
      end
      File.chmod(0o600, path)
    end

    def overlay_settings(config = read_config)
      overlay = config["overlay"].is_a?(Hash) ? config["overlay"] : {}
      settings = DEFAULT_OVERLAY_SETTINGS.dup
      alignment = overlay["alignment"].to_s
      width = overlay["width"].to_s
      settings["alignment"] = alignment if OVERLAY_ALIGNMENTS.include?(alignment)
      settings["width"] = width if OVERLAY_WIDTHS.include?(width)
      settings
    end

    def update_overlay_settings(values)
      raise "Overlay settings must be an object" unless values.is_a?(Hash)

      config = read_config
      overlay = config["overlay"].is_a?(Hash) ? config["overlay"].dup : {}
      values.each do |key, value|
        key = key.to_s
        value = value.to_s
        case key
        when "alignment"
          raise "Overlay alignment must be left, center, or right" unless OVERLAY_ALIGNMENTS.include?(value)
        when "width"
          raise "Overlay width must be capped or maximum" unless OVERLAY_WIDTHS.include?(value)
        else
          raise "Unknown overlay setting: #{key}"
        end
        overlay[key] = value
      end
      config["overlay"] = overlay
      write_config(config)
      overlay_settings(config)
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

    def prompt_templates(reserved_commands: [])
      prompts_root = File.join(config_dir, "prompts")
      return [] unless Dir.exist?(prompts_root)

      reserved = reserved_commands.map(&:to_s)
      seen = {}
      Dir.glob(File.join(prompts_root, "*.md")).sort.filter_map do |path|
        template = parse_prompt_template(path)
        next unless template

        if reserved.include?(template.command)
          warn "Warning: skipping Kward prompt command /#{template.command}: reserved command"
          next
        end
        if seen[template.command]
          warn "Warning: skipping duplicate Kward prompt command /#{template.command}: #{path}"
          next
        end

        seen[template.command] = true
        template
      end
    rescue StandardError => e
      warn "Warning: skipping Kward prompt templates in #{prompts_root}: #{e.message}"
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
      frontmatter, = markdown_parts(path)
      name = frontmatter.fetch("name", "").to_s.strip
      name = File.basename(File.dirname(path)) if name.empty?
      description = frontmatter.fetch("description", "").to_s.strip

      Skill.new(name: name, description: description, folder: File.dirname(path), path: path)
    rescue StandardError => e
      warn "Warning: skipping Kward skill #{path}: #{e.message}"
      nil
    end

    def parse_prompt_template(path)
      command = File.basename(path, ".md")
      unless command.match?(/\A[A-Za-z0-9][A-Za-z0-9_-]*\z/)
        warn "Warning: skipping Kward prompt template #{path}: invalid command name"
        return nil
      end

      frontmatter, body = markdown_parts(path)
      PromptTemplate.new(
        command: command,
        description: frontmatter.fetch("description", "").to_s.strip,
        argument_hint: frontmatter.fetch("argument-hint", "").to_s.strip,
        body: body,
        path: path
      )
    rescue StandardError => e
      warn "Warning: skipping Kward prompt template #{path}: #{e.message}"
      nil
    end

    def markdown_parts(path)
      content = File.read(path)
      return [{}, content] unless content.start_with?("---\n", "---\r\n")

      _opening, rest = content.split(/\A---\r?\n/, 2)
      yaml_text, body = rest.to_s.split(/\r?\n---\r?\n/, 2)
      raise "missing frontmatter closing delimiter" if body.nil?

      data = yaml_text.to_s.empty? ? {} : YAML.safe_load(yaml_text, permitted_classes: [], aliases: false)
      frontmatter = data.is_a?(Hash) ? data.transform_keys(&:to_s) : {}
      [frontmatter, body]
    end

    def inside_directory?(path, base)
      path == base || path.start_with?(base + File::SEPARATOR)
    end
  end
end

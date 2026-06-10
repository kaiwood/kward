require "fileutils"
require "json"
require "pathname"
require "yaml"

module Kward
  module ConfigFiles
    MAX_SKILL_FILE_BYTES = 100_000
    DEFAULT_OVERLAY_SETTINGS = { "alignment" => "center", "width" => "maximum" }.freeze
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

    def cache_dir
      File.join(config_dir, "cache")
    end

    def code_search_cache_dir
      File.join(cache_dir, "code_search")
    end

    def news_cache_path
      File.join(cache_dir, "news", "hacker_news.json")
    end

    def memory_dir
      File.join(config_dir, "memory")
    end

    def memory_core_path
      File.join(memory_dir, "core.json")
    end

    def memory_soft_path
      File.join(memory_dir, "soft.jsonl")
    end

    def memory_events_path
      File.join(memory_dir, "events.jsonl")
    end

    def read_config(path = config_path)
      path = File.expand_path(path)
      return {} unless File.exist?(path)

      JSON.parse(File.read(path))
    rescue JSON::ParserError
      raise "Invalid Kward config JSON: #{path}"
    end

    def write_config(config, path = config_path)
      path = File.expand_path(path)
      FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
      File.open(path, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |file|
        file.write(JSON.pretty_generate(config))
        file.write("\n")
      end
      File.chmod(0o600, path)
    end

    def update_config(values, path = config_path)
      raise "Config values must be an object" unless values.is_a?(Hash)

      config = read_config(path)
      values.each { |key, value| config[key.to_s] = value }
      write_config(config, path)
      config
    end

    def delete_config_key(key, path = config_path)
      config = read_config(path)
      existed = config.key?(key.to_s)
      config.delete(key.to_s)
      write_config(config, path) if existed
      existed
    end

    def config_value(config, *keys)
      keys.each do |key|
        text = presence(config[key])
        return text if text
      end
      nil
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

    def persona_prompt(workspace_root, model: nil, reasoning_effort: nil, now: Time.now, config: read_config)
      text = persona_entries(workspace_root: workspace_root, model: model, reasoning_effort: reasoning_effort, now: now, config: config).map do |entry|
        entry[:prompt]
      end.join("\n\n")
      return nil if text.empty?

      text
    end

    def active_persona_label(workspace_root:, model: nil, config: read_config)
      personas = config["personas"]
      return nil unless personas.is_a?(Hash)

      labels = crew_character_labels(personas)
      active_label = persona_label_for_key(personas["default"], labels) unless personas["default"].nil?

      workspaces = personas["workspaces"]
      if workspaces.is_a?(Hash)
        root = canonical_workspace_root(workspace_root)
        workspaces.each do |path, key|
          next unless canonical_workspace_root(path) == root

          active_label = persona_label_for_key(key, labels)
          break
        end
      end

      models = personas["models"]
      if models.is_a?(Hash) && !model.to_s.empty? && models.key?(model.to_s)
        active_label = persona_label_for_key(models[model.to_s], labels)
      end

      active_label
    end

    def persona_entries(workspace_root:, model: nil, reasoning_effort: nil, now: Time.now, config: read_config, include_reasoning: true)
      personas = config["personas"]
      return [] unless personas.is_a?(Hash)

      characters = crew_characters(personas)
      entries = []

      add_persona_entry(entries, "default", resolved_persona_text(personas["default"], characters: characters))

      workspaces = personas["workspaces"]
      if workspaces.is_a?(Hash)
        root = canonical_workspace_root(workspace_root)
        workspaces.each do |path, key|
          if canonical_workspace_root(path) == root
            add_persona_entry(entries, "workspace", resolved_persona_text(key, characters: characters), name: path)
            break
          end
        end
      end

      models = personas["models"]
      add_persona_entry(entries, "model", resolved_persona_text(models[model.to_s], characters: characters), name: model.to_s) if models.is_a?(Hash) && !model.to_s.empty?

      modifiers = personas["persona_modifiers"]
      if modifiers.is_a?(Hash)
        if include_reasoning
          reasoning = modifiers["reasoning"]
          add_persona_entry(entries, "reasoning", reasoning[reasoning_effort.to_s]) if reasoning.is_a?(Hash) && !reasoning_effort.to_s.empty?
        end

        time_of_day = modifiers["time_of_day"]
        bucket = time_of_day_bucket(now)
        add_persona_entry(entries, "time_of_day", time_of_day[bucket], name: bucket) if time_of_day.is_a?(Hash)

        weekday = modifiers["weekday"]
        day = weekday_name(now)
        add_persona_entry(entries, "weekday", weekday[day], name: day) if weekday.is_a?(Hash)

        add_persona_entry(entries, "suffix", modifiers["suffix"])
      end

      entries
    end
    def workspace_agents_prompt(workspace_root)
      root = canonical_workspace_root(workspace_root)
      path = File.join(root, "AGENTS.md")
      return nil unless File.exist?(path)

      File.read(path)
    rescue StandardError => e
      warn "Warning: skipping workspace AGENTS.md #{path}: #{e.message}"
      nil
    end

    def workspace_config(workspace_root, config = read_config)
      workspaces = config["workspaces"]
      return nil unless workspaces.is_a?(Hash)

      root = canonical_workspace_root(workspace_root)
      workspaces.each do |path, entry|
        return entry if canonical_workspace_root(path) == root
      end
      nil
    end

    def canonical_workspace_root(path)
      expanded = File.expand_path(path.to_s.empty? ? Dir.pwd : path.to_s)
      File.directory?(expanded) ? File.realpath(expanded) : expanded
    end

    def add_persona_entry(entries, layer, value, name: nil)
      text = presence(value)
      return unless text

      entries << { layer: layer.to_s, name: name.to_s, prompt: text }
    end

    def crew_characters(personas)
      raw = personas["characters"] || personas["crew"]
      return {} unless raw

      if raw.is_a?(Hash)
        parse_named_characters(raw)
      elsif raw.is_a?(Array)
        parse_named_characters_array(raw)
      else
        {}
      end
    end

    def crew_character_labels(personas)
      raw = personas["characters"] || personas["crew"]
      return {} unless raw

      if raw.is_a?(Hash)
        parse_named_character_labels(raw)
      elsif raw.is_a?(Array)
        parse_named_character_labels_array(raw)
      else
        {}
      end
    end

    def resolved_persona_text(value, characters: {})
      return nil if value.nil?

      key = value.to_s.strip
      return nil if key.empty?

      text = characters[key.to_s]
      return text unless text.to_s.empty?

      value
    end

    def persona_label_for_key(value, labels)
      key = value.to_s.strip
      return nil if key.empty?

      presence(labels[key])
    end

    def parse_named_characters(raw)
      raw.each_with_object({}) do |(key, definition), mapping|
        instruction = extract_character_instruction(definition)
        next if instruction.nil?

        mapping[key.to_s] = instruction
      end
    end

    def parse_named_characters_array(raw)
      raw.each_with_object({}) do |entry, mapping|
        char_key = nil
        definition = nil

        if entry.is_a?(Hash) && entry.length == 1 && entry.keys.first.is_a?(String)
          char_key = entry.keys.first
          definition = entry.values.first
        elsif entry.is_a?(Hash)
          char_key = entry["key"] || entry[:key] || entry["id"] || entry[:id] || entry["name"] || entry[:name]
          definition = entry
        end

        next if char_key.to_s.empty?

        instruction = extract_character_instruction(definition)
        next if instruction.to_s.empty?

        mapping[char_key.to_s] = instruction
      end
    end

    def parse_named_character_labels(raw)
      raw.each_with_object({}) do |(key, definition), mapping|
        label = extract_character_label(definition)
        next if label.nil?

        mapping[key.to_s] = label
      end
    end

    def parse_named_character_labels_array(raw)
      raw.each_with_object({}) do |entry, mapping|
        char_key = nil
        definition = nil

        if entry.is_a?(Hash) && entry.length == 1 && entry.keys.first.is_a?(String)
          char_key = entry.keys.first
          definition = entry.values.first
        elsif entry.is_a?(Hash)
          char_key = entry["key"] || entry[:key] || entry["id"] || entry[:id] || entry["name"] || entry[:name]
          definition = entry
        end

        next if char_key.to_s.empty?

        label = extract_character_label(definition)
        next if label.to_s.empty?

        mapping[char_key.to_s] = label
      end
    end

    def extract_character_label(definition)
      return nil unless definition.is_a?(Hash)

      presence(definition["label"] || definition[:label])
    end

    def extract_character_instruction(definition)
      return nil if definition.nil?

      if definition.is_a?(Hash)
        value = definition["instruction"] || definition[:instruction]
        return presence(value)
      end

      presence(definition)
    end

    def add_persona_part(parts, value)
      text = presence(value)
      parts << text if text
    end

    def time_of_day_bucket(now)
      hour = now.hour
      return "morning" if hour >= 5 && hour < 11
      return "before_lunch" if hour == 11
      return "late_evening" if hour >= 21 || hour < 5

      nil
    end

    def weekday_name(now)
      %w[sunday monday tuesday wednesday thursday friday saturday][now.wday]
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

    def plugin_dir
      File.expand_path("~/.kward/plugins")
    end

    def plugin_paths
      plugins_root = plugin_dir
      warn_legacy_plugin_dir(plugins_root)
      return [] unless Dir.exist?(plugins_root)

      Dir.glob(File.join(plugins_root, "*.rb")).sort
    rescue StandardError => e
      warn "Warning: skipping Kward plugins in #{plugins_root}: #{e.message}"
      []
    end

    def warn_legacy_plugin_dir(plugins_root)
      config_path = ENV["KWARD_CONFIG_PATH"]
      return if config_path.to_s.empty?

      legacy_root = File.expand_path(File.join(File.dirname(config_path), "plugins"))
      return if legacy_root == File.expand_path(plugins_root)
      return unless Dir.exist?(legacy_root)

      warn "Warning: ignoring Kward plugins in #{legacy_root}; plugins are only loaded from #{File.expand_path(plugins_root)}"
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

    def presence(value)
      text = value.to_s
      text.empty? ? nil : text
    end
  end
end

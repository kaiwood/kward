require "fileutils"
require "json"
require "yaml"
require_relative "private_file"
require_relative "prompts/templates"
require_relative "skills/registry"

module Kward
  # Resolves Kward configuration, cache, memory, prompt, skill, and plugin
  # paths, and reads/writes the JSON config file used by the CLI and RPC server.
  module ConfigFiles
    MAX_SKILL_FILE_BYTES = 100_000
    MAX_PROMPT_FILE_BYTES = 32 * 1024
    DEFAULT_OVERLAY_SETTINGS = { "alignment" => "center", "width" => "maximum" }.freeze
    DEFAULT_PERSONAS = {
      "characters" => [
        {
          "key" => "kward",
          "label" => "Kward",
          "instruction" => "Your name is Kward, the grim Andruid - robotic keeper of the Forrest of Code, protecting the nature of good engineering priciples. Speak like an old druid, be suspicous of everyone, but with a good intend."
        }
      ],
      "default" => "kward"
    }.freeze
    OVERLAY_ALIGNMENTS = %w[left center right].freeze
    OVERLAY_WIDTHS = %w[capped maximum].freeze

    Skill = Struct.new(:name, :description, :folder, :path, keyword_init: true)
    PromptTemplate = Struct.new(:command, :description, :argument_hint, :body, :path, keyword_init: true) do
      def expand(arguments)
        body.gsub("$ARGUMENTS", arguments.to_s)
      end
    end

    module_function

    # Directory that contains Kward's user config and adjacent prompt/skill
    # data. Defaults to `~/.kward`, or the directory of `KWARD_CONFIG_PATH`.
    #
    # @return [String] expanded config directory path
    def config_dir
      config_path = ENV["KWARD_CONFIG_PATH"]
      return File.expand_path(File.dirname(config_path)) if config_path && !config_path.empty?

      File.expand_path("~/.kward")
    end

    # @return [String] expanded JSON config file path
    def config_path
      File.expand_path(ENV["KWARD_CONFIG_PATH"] || File.join(config_dir, "config.json"))
    end

    def cache_dir
      File.join(config_dir, "cache")
    end

    def default_config
      require_relative "model/model_info"

      {
        "openai_model" => ModelInfo::DEFAULT_OPENAI_MODEL,
        "openai_reasoning_effort" => ModelInfo::DEFAULT_REASONING_EFFORT,
        "openrouter_model" => ModelInfo::DEFAULT_OPENROUTER_MODEL,
        "openrouter_reasoning_effort" => ModelInfo::DEFAULT_REASONING_EFFORT,
        "copilot_model" => ModelInfo::DEFAULT_COPILOT_MODEL,
        "copilot_reasoning_effort" => ModelInfo::DEFAULT_REASONING_EFFORT,
        "personas" => JSON.parse(JSON.generate(DEFAULT_PERSONAS))
      }
    end

    def ensure_default_config!(path = config_path)
      path = File.expand_path(path)
      return false if File.exist?(path)

      write_config(default_config, path)
      true
    end

    def code_search_cache_dir
      File.join(cache_dir, "code_search")
    end

    # @return [String] directory containing structured memory files
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

    # Reads the JSON config file.
    #
    # Missing files are treated as an empty config. Invalid JSON raises a
    # user-facing error that includes the file path.
    #
    # @param path [String] config file path
    # @return [Hash] parsed config object
    def read_config(path = config_path)
      path = File.expand_path(path)
      return {} unless File.exist?(path)

      JSON.parse(File.read(path))
    rescue JSON::ParserError
      raise "Invalid Kward config JSON: #{path}"
    end

    # Writes config JSON using private file permissions.
    #
    # @param config [Hash] config object to persist
    # @param path [String] config file path
    def write_config(config, path = config_path)
      PrivateFile.write_json(path, config)
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

    # Returns validated overlay settings with defaults for missing or invalid
    # values.
    #
    # @param config [Hash] parsed config object
    # @return [Hash] overlay settings with `alignment` and `width`
    def overlay_settings(config = read_config)
      overlay = config["overlay"].is_a?(Hash) ? config["overlay"] : {}
      settings = DEFAULT_OVERLAY_SETTINGS.dup
      alignment = overlay["alignment"].to_s
      width = overlay["width"].to_s
      settings["alignment"] = alignment if OVERLAY_ALIGNMENTS.include?(alignment)
      settings["width"] = width if OVERLAY_WIDTHS.include?(width)
      settings
    end

    def composer_busy_help?(config = read_config)
      composer = config["composer"].is_a?(Hash) ? config["composer"] : {}
      composer["busy_help"] != false
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

    # Reads global agent instructions from the config directory.
    #
    # @return [String, nil] prompt text, or nil when absent/too large
    def agents_prompt
      path = File.join(config_dir, "AGENTS.md")
      read_prompt_file(path, "Kward prompt file")
    end

    # Builds persona prompt text from default, workspace, model, reasoning,
    # time-of-day, weekday, and suffix config entries.
    #
    # @param workspace_root [String] active workspace root
    # @param model [String, nil] active model name
    # @param reasoning_effort [String, nil] active reasoning effort
    # @param now [Time] local time used for time-based modifiers
    # @param config [Hash] parsed config object
    # @return [String, nil] persona prompt text when entries match
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
      read_prompt_file(path, "workspace AGENTS.md")
    end

    def read_prompt_file(path, label)
      return nil unless File.exist?(path)

      size = File.size(path)
      if size > MAX_PROMPT_FILE_BYTES
        warn "Warning: skipping #{label} #{path}: file too large (#{size} bytes; limit is #{MAX_PROMPT_FILE_BYTES} bytes)"
        return nil
      end

      File.read(path)
    rescue StandardError => e
      warn "Warning: skipping #{label} #{path}: #{e.message}"
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

    # Lists configured skills discovered under the config directory.
    #
    # @return [Array<Skill>] skill metadata available to the model
    def skills
      skills_registry.skills
    end

    # @return [String] trusted user plugin directory
    def plugin_dir
      File.expand_path("~/.kward/plugins")
    end

    # Finds trusted top-level plugin files.
    #
    # Plugins are intentionally loaded only from `~/.kward/plugins`, not from a
    # workspace or custom `KWARD_CONFIG_PATH` directory.
    #
    # @return [Array<String>] sorted plugin file paths
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
    def read_skill_file(name, relative_path = nil)
      skills_registry.read_skill_file(name, relative_path)
    end

    def skills_registry
      Skills::Registry.new(
        config_dir: config_dir,
        skill_class: Skill,
        max_file_bytes: MAX_SKILL_FILE_BYTES,
        markdown_parser: method(:markdown_parts),
        inside_directory: method(:inside_directory?)
      )
    end

    def prompt_template_registry
      Prompts::Templates.new(
        config_dir: config_dir,
        template_class: PromptTemplate,
        markdown_parser: method(:markdown_parts)
      )
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

require "digest"
require "fileutils"
require "json"
require "yaml"
require_relative "frontmatter"
require_relative "private_file"
require_relative "ekwsh"
require_relative "editor_mode"
require_relative "diff_view_mode"
require_relative "prompts/templates"
require_relative "skills/registry"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Resolves Kward configuration, cache, memory, prompt, skill, and plugin
  # paths, and reads/writes the JSON config file used by the CLI and RPC server.
  #
  # This module is the configuration boundary, not a runtime settings cache.
  # Most methods read the filesystem each time so CLI commands and RPC reloads can
  # observe edits made outside the process. Callers that need caching should own
  # invalidation explicitly, as `Client#reload_config` does for provider state.
  #
  # Keep path decisions here. Higher-level code should ask `ConfigFiles` for
  # config, prompt, skill, plugin, cache, memory, and session locations instead of
  # reconstructing `~/.kward` paths independently.
  module ConfigFiles
    class ConfigError < StandardError
      attr_reader :path, :format, :detail

      def initialize(path:, format:, detail:)
        @path = path
        @format = format
        @detail = detail
        super("Invalid Kward config #{format}: #{path}: #{detail}")
      end
    end

    MAX_SKILL_FILE_BYTES = 100_000
    MAX_PROMPT_FILE_BYTES = 32 * 1024
    DEFAULT_OVERLAY_SETTINGS = { "alignment" => "center", "width" => "maximum" }.freeze
    DEFAULT_PERSONAS = {
      "characters" => [
        {
          "key" => "kward",
          "label" => "Kward",
          "instruction" => "Your name is Kward, the grim Andruid - robotic keeper of the Forest of Code, protecting the nature of good engineering principles. Speak like an old druid, be suspicious of everyone, but with good intent."
        }
      ],
      "default" => "kward"
    }.freeze
    OVERLAY_ALIGNMENTS = %w[left center right].freeze
    OVERLAY_WIDTHS = %w[capped maximum].freeze

    Skill = Struct.new(:name, :description, :folder, :path, :license, :compatibility, :metadata, :allowed_tools, keyword_init: true)
    PromptTemplate = Struct.new(:command, :description, :argument_hint, :body, :path, keyword_init: true) do
      def expand(arguments)
        body.gsub("$ARGUMENTS", arguments.to_s)
      end
    end

    @skip_config = false

    module_function

    def skip_config=(value)
      @skip_config = value
    end

    def skip_config?
      @skip_config == true
    end

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

    def ekwsh_config_path
      File.join(config_dir, "ekwsh.yml")
    end

    def workspace_hooks_path(root = Dir.pwd)
      File.join(File.expand_path(root), ".kward", "hooks.json")
    end

    def trusted_workspace_hooks_path
      File.join(config_dir, "trusted_workspace_hooks.json")
    end

    def default_config
      {
        "personas" => JSON.parse(JSON.generate(DEFAULT_PERSONAS)),
        "memory" => {
          "enabled" => false,
          "auto_summary" => false
        },
        "composer" => {
          "busy_help" => true,
          "tab_keybindings" => "auto"
        },
        "editor" => {
          "mode" => "modern",
          "auto_indent" => true,
          "auto_close_pairs" => true,
          "soft_wrap" => true,
          "bar_cursor" => true,
          "line_numbers" => "absolute",
          "diff_view" => "auto"
        },
        "overlay" => DEFAULT_OVERLAY_SETTINGS.dup,
        "web_search" => {
          "enabled" => true,
          "provider" => "auto",
          "allow_model_providers" => false
        },
        "sessions" => {
          "auto_resume" => false
        },
        "skills" => {
          "trust_project" => false
        },
        "enforce_workspace_agents_file" => false,
        "mcpServers" => {},
        "tools" => {
          "workspace_guardrails" => true
        }
      }
    end

    # Performs ensure default config for configuration file and path handling.
    def ensure_default_config!(path = config_path)
      path = File.expand_path(path)
      return false if skip_config? && path == config_path
      return false if File.exist?(path)

      write_config(default_config, path)
      true
    end

    def code_search_cache_dir
      File.join(cache_dir, "code_search")
    end

    def openrouter_models_cache_path
      File.join(cache_dir, "openrouter_models.json")
    end

    def project_browser_state_path
      File.join(cache_dir, "project_browser_state.json")
    end

    def prompt_history_path(cwd, config_dir: self.config_dir, kind: "prompt")
      key = Digest::SHA256.hexdigest(canonical_workspace_root(cwd))[0, 24]
      return File.join(config_dir, "history", "#{key}.jsonl") if kind.to_s == "prompt"

      File.join(config_dir, "history", kind.to_s, "#{key}.jsonl")
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
    # user-facing error that includes the file path. This method does not merge
    # defaults; callers should apply feature-specific defaults at the point where
    # behavior is decided.
    #
    # @param path [String] config file path
    # @return [Hash] parsed config object
    def read_config(path = config_path)
      path = File.expand_path(path)
      return {} if skip_config? && path == config_path
      return {} unless File.exist?(path)

      JSON.parse(File.read(path))
    rescue JSON::ParserError => e
      raise ConfigError.new(path: path, format: "JSON", detail: e.message)
    end

    # Writes config JSON using private file permissions.
    #
    # @param config [Hash] config object to persist
    # @param path [String] config file path
    def write_config(config, path = config_path)
      path = File.expand_path(path)
      raise "Cannot write Kward config while --skip-config is active: #{path}" if skip_config? && path == config_path

      PrivateFile.write_json(path, config)
    end

    def lifecycle_hooks_config(workspace_root = Dir.pwd)
      config = read_config
      workspace_config = read_trusted_workspace_hooks_config(workspace_root)
      return config if workspace_config.empty?

      merge_hooks_config(config, workspace_config)
    end

    def read_trusted_workspace_hooks_config(workspace_root = Dir.pwd)
      path = workspace_hooks_path(workspace_root)
      return {} unless workspace_hooks_trusted?(workspace_root)

      read_config(path)
    end

    def workspace_hooks_trusted?(workspace_root = Dir.pwd)
      path = workspace_hooks_path(workspace_root)
      return false unless File.file?(path)

      trusted = read_trusted_workspace_hooks
      trusted[File.expand_path(path)] == workspace_hooks_digest(workspace_root)
    end

    def trust_workspace_hooks!(workspace_root = Dir.pwd)
      path = workspace_hooks_path(workspace_root)
      raise "No workspace hook config found: #{path}" unless File.file?(path)

      trusted = read_trusted_workspace_hooks
      trusted[File.expand_path(path)] = workspace_hooks_digest(workspace_root)
      PrivateFile.write_json(trusted_workspace_hooks_path, trusted)
    end

    def untrust_workspace_hooks!(workspace_root = Dir.pwd)
      path = File.expand_path(workspace_hooks_path(workspace_root))
      trusted = read_trusted_workspace_hooks
      trusted.delete(path)
      PrivateFile.write_json(trusted_workspace_hooks_path, trusted)
    end

    def workspace_hooks_digest(workspace_root = Dir.pwd)
      Digest::SHA256.file(workspace_hooks_path(workspace_root)).hexdigest
    end

    def read_trusted_workspace_hooks
      config = read_config(trusted_workspace_hooks_path)
      config.is_a?(Hash) ? config : {}
    rescue ConfigError
      {}
    end

    def merge_hooks_config(config, workspace_config)
      merged = JSON.parse(JSON.generate(config || {}))
      merged["hooks"] = merge_hook_maps(merged["hooks"], workspace_config["hooks"] || workspace_config[:hooks])
      merged
    end

    def merge_hook_maps(left, right)
      left = left.is_a?(Hash) ? left : {}
      right = right.is_a?(Hash) ? right : {}
      merged = JSON.parse(JSON.generate(left))
      right.each do |event, entries|
        merged[event.to_s] = Array(merged[event.to_s]) + Array(entries)
      end
      merged
    end

    def read_ekwsh_config(path = ekwsh_config_path)
      path = File.expand_path(path)
      return normalize_ekwsh_config(nil) unless File.exist?(path)

      data = YAML.safe_load(File.read(path), permitted_classes: [], aliases: false)
      normalize_ekwsh_config(data)
    rescue Psych::SyntaxError => e
      raise "Invalid ekwsh YAML config: #{path}: #{e.message}"
    end

    def normalize_ekwsh_config(data)
      data = data.transform_keys(&:to_s) if data.is_a?(Hash)
      settings = data.is_a?(Hash) ? data : {}
      {
        shell: normalize_ekwsh_shell(settings["shell"]),
        timeout_seconds: normalize_positive_integer(settings["timeout_seconds"], Ekwsh::DEFAULT_TIMEOUT_SECONDS),
        max_output_bytes: normalize_positive_integer(settings["max_output_bytes"], Ekwsh::DEFAULT_MAX_OUTPUT_BYTES),
        history_limit: normalize_positive_integer(settings["history_limit"], Ekwsh::DEFAULT_HISTORY_LIMIT),
        env: normalize_ekwsh_env(settings["env"]),
        aliases: normalize_ekwsh_aliases(settings["aliases"])
      }
    end

    def normalize_ekwsh_shell(value)
      shell = value.to_s.strip
      return Ekwsh::DEFAULT_SHELL if shell.empty?
      return shell if shell.start_with?("/") && File.executable?(shell)

      Ekwsh::DEFAULT_SHELL
    end

    def normalize_positive_integer(value, default)
      integer = Integer(value)
      integer.positive? ? integer : default
    rescue ArgumentError, TypeError
      default
    end

    def normalize_ekwsh_env(values)
      return {} unless values.is_a?(Hash)

      values.each_with_object({}) do |(key, value), result|
        key = key.to_s
        next unless key.match?(/\A[A-Za-z_][A-Za-z0-9_]*\z/)
        next if value.nil?

        result[key] = value.to_s
      end
    end

    def normalize_ekwsh_aliases(values)
      return {} unless values.is_a?(Hash)

      values.each_with_object({}) do |(name, command), result|
        name = name.to_s
        command = command.to_s.strip
        next unless Ekwsh.valid_alias_name?(name)
        next if command.empty?

        result[name] = command
      end
    end

    # Merges top-level config values and writes the updated config privately.
    def update_config(values, path = config_path)
      raise "Config values must be an object" unless values.is_a?(Hash)

      config = read_config(path)
      values.each { |key, value| config[key.to_s] = value }
      write_config(config, path)
      config
    end

    # Merges values into a one-level nested config section and writes privately.
    def update_nested_config(section, values, path = config_path)
      raise "Config values must be an object" unless values.is_a?(Hash)

      config = read_config(path)
      current = config[section.to_s].is_a?(Hash) ? config[section.to_s].dup : {}
      config[section.to_s] = current.merge(values.transform_keys(&:to_s))
      write_config(config, path)
      config
    end

    # Removes a top-level config key when it exists.
    def delete_config_key(key, path = config_path)
      config = read_config(path)
      existed = config.key?(key.to_s)
      config.delete(key.to_s)
      write_config(config, path) if existed
      existed
    end

    # Returns the first present non-empty string value among several config keys.
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

    # Returns whether the composer should show busy-state keyboard help.
    def composer_busy_help?(config = read_config)
      composer = config["composer"].is_a?(Hash) ? config["composer"] : {}
      composer["busy_help"] != false
    end

    # Returns the configured tab keybinding family, or auto when unset/invalid.
    def composer_tab_keybindings(config = read_config)
      composer = config["composer"].is_a?(Hash) ? config["composer"] : {}
      value = composer["tab_keybindings"].to_s.downcase
      %w[auto ctrl alt].include?(value) ? value : "auto"
    end

    # Returns the built-in TUI editor keymap mode.
    def editor_mode(config = read_config)
      editor = config["editor"].is_a?(Hash) ? config["editor"] : {}
      EditorMode.normalize(editor["mode"])
    end

    # Returns whether the built-in TUI editor should auto-indent new lines.
    def editor_auto_indent?(config = read_config)
      editor = config["editor"].is_a?(Hash) ? config["editor"] : {}
      editor["auto_indent"] != false
    end

    # Returns whether the built-in TUI editor should auto-close typed pairs.
    def editor_auto_close_pairs?(config = read_config)
      editor = config["editor"].is_a?(Hash) ? config["editor"] : {}
      editor["auto_close_pairs"] != false
    end

    # Returns whether the built-in TUI editor should soft-wrap long lines.
    def editor_soft_wrap?(config = read_config)
      editor = config["editor"].is_a?(Hash) ? config["editor"] : {}
      editor["soft_wrap"] != false
    end

    # Returns whether editable built-in TUI editor buffers should use a bar cursor.
    def editor_bar_cursor?(config = read_config)
      editor = config["editor"].is_a?(Hash) ? config["editor"] : {}
      editor["bar_cursor"] != false
    end

    # Returns the built-in TUI editor line-number display mode.
    def editor_line_numbers(config = read_config)
      editor = config["editor"].is_a?(Hash) ? config["editor"] : {}
      EditorMode.normalize_line_numbers(editor["line_numbers"])
    end

    # Returns the integrated diff viewer display mode.
    def diff_view(config = read_config)
      editor = config["editor"].is_a?(Hash) ? config["editor"] : {}
      DiffViewMode.normalize(editor["diff_view"])
    end

    # Returns whether file tools must stay inside the active workspace root.
    def workspace_guardrails_enabled?(config = read_config)
      tools = config["tools"].is_a?(Hash) ? config["tools"] : {}
      tools["workspace_guardrails"] != false
    end

    # Returns whether project-level Agent Skills should be loaded from the workspace.
    def project_skills_trusted?(config = read_config)
      skills = config["skills"].is_a?(Hash) ? config["skills"] : {}
      skills["trust_project"] == true
    end

    # Returns whether new frontends should resume the last active session automatically.
    def session_auto_resume_enabled?(config = read_config)
      sessions = config["sessions"].is_a?(Hash) ? config["sessions"] : {}
      sessions["auto_resume"] == true
    end

    # Returns whether workspace AGENTS.md contents should be injected directly
    # instead of a compact read-when-relevant instruction.
    def enforce_workspace_agents_file?(config = read_config)
      config["enforce_workspace_agents_file"] == true
    end

    # Returns the nested web-search config object, or an empty config when absent.
    def web_search_config(config = read_config)
      value = config["web_search"]
      value.is_a?(Hash) ? value : {}
    end

    # Returns configured MCP stdio servers, or an empty config when absent.
    def mcp_servers(config = read_config)
      value = config["mcpServers"] || config.dig("mcp", "servers")
      value.is_a?(Hash) ? value : {}
    end

    # Validates and persists terminal overlay settings.
    def update_overlay_settings(values)
      raise "Overlay settings must be an object" unless values.is_a?(Hash)

      config = read_config
      overlay = overlay_settings(config)
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

    # Reads global principle instructions from the config directory.
    #
    # `PRINCIPLES.md` is preferred. `AGENTS.md` remains a backwards-compatible
    # alias for existing installations.
    #
    # @return [String, nil] prompt text, or nil when absent/too large
    def agents_prompt
      path = config_principles_path
      return read_prompt_file(path, "Kward principles file") if File.exist?(path)

      read_prompt_file(config_agents_path, "Kward AGENTS.md alias")
    end

    def config_principles_path
      File.join(config_dir, "PRINCIPLES.md")
    end

    def config_agents_path
      File.join(config_dir, "AGENTS.md")
    end

    # Builds persona prompt text from default, workspace, model, reasoning,
    # time-of-day, weekday, and suffix config entries.
    #
    # Persona resolution is intentionally data-driven so users can edit config
    # without plugin code. Keep new persona selectors additive and deterministic;
    # prompt construction depends on stable ordering.
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

    # Returns the label of the persona selected by default/workspace/model rules.
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
      active_persona = { layer: "default", value: personas["default"], name: nil }

      workspaces = personas["workspaces"]
      if workspaces.is_a?(Hash)
        root = canonical_workspace_root(workspace_root)
        workspaces.each do |path, key|
          if canonical_workspace_root(path) == root
            active_persona = { layer: "workspace", value: key, name: path }
            break
          end
        end
      end

      models = personas["models"]
      if models.is_a?(Hash) && !model.to_s.empty? && models.key?(model.to_s)
        active_persona = { layer: "model", value: models[model.to_s], name: model.to_s }
      end

      add_persona_entry(
        entries,
        active_persona.fetch(:layer),
        resolved_persona_text(active_persona.fetch(:value), characters: characters),
        name: active_persona[:name]
      )

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

    def workspace_agents_path(workspace_root)
      File.join(canonical_workspace_root(workspace_root), "AGENTS.md")
    end

    def workspace_agents_file?(workspace_root)
      File.exist?(workspace_agents_path(workspace_root))
    end

    def workspace_agents_prompt(workspace_root)
      read_prompt_file(workspace_agents_path(workspace_root), "workspace AGENTS.md")
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
      named_character_values(personas) do |_key, definition|
        extract_character_instruction(definition)
      end
    end

    def crew_character_labels(personas)
      named_character_values(personas) do |_key, definition|
        extract_character_label(definition)
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

    def named_character_values(personas)
      character_entries(personas["characters"] || personas["crew"]).each_with_object({}) do |(key, definition), mapping|
        value = yield(key, definition)
        next if value.to_s.empty?

        mapping[key.to_s] = value
      end
    end

    def character_entries(raw)
      case raw
      when Hash
        raw.map { |key, definition| [key, definition] }
      when Array
        raw.filter_map { |entry| character_entry(entry) }
      else
        []
      end
    end

    def character_entry(entry)
      return nil unless entry.is_a?(Hash)

      if entry.length == 1 && entry.keys.first.is_a?(String)
        [entry.keys.first, entry.values.first]
      else
        key = entry["key"] || entry[:key] || entry["id"] || entry[:id] || entry["name"] || entry[:name]
        key.to_s.empty? ? nil : [key, entry]
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
    def skills(workspace_root: Dir.pwd)
      skills_registry(workspace_root: workspace_root).skills
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
      return [] unless Dir.exist?(plugins_root)

      Dir.glob(File.join(plugins_root, "*.rb")).sort
    rescue StandardError => e
      warn "Warning: skipping Kward plugins in #{plugins_root}: #{e.message}"
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

    def skills_registry(workspace_root: Dir.pwd)
      Skills::Registry.new(
        config_dir: config_dir,
        workspace_root: workspace_root,
        project_skills_trusted: project_skills_trusted?,
        skill_class: Skill,
        max_file_bytes: MAX_SKILL_FILE_BYTES,
        markdown_parser: ->(path) { Frontmatter.markdown_parts(path, lenient: true) },
        inside_directory: method(:inside_directory?)
      )
    end

    def prompt_template_registry
      Prompts::Templates.new(
        config_dir: config_dir,
        template_class: PromptTemplate,
        markdown_parser: ->(path) { Frontmatter.markdown_parts(path) }
      )
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

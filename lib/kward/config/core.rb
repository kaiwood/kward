# Core configuration paths, persistence, and shared configuration values.
module Kward
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
    PROJECT_BROWSER_ICON_THEMES = %w[off nerd-font].freeze
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
    @warning_sink = nil

    module Core
      extend self

      def skip_config=(value)
        @skip_config = value
      end

      def warning_sink=(sink)
        @warning_sink = sink
      end

      def warning_sink
        @warning_sink
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

      # @return [String] directory containing reusable local caches
      def cache_dir
        File.join(config_dir, "cache")
      end

      # @return [String] embedded-shell rc config path
      def kwshrc_path
        File.join(config_dir, "kwshrc")
      end

      # @return [Array<String>] embedded-shell rc config paths in load order
      def kwshrc_paths
        [kwshrc_path, File.expand_path("~/.kwshrc")].uniq
      end

      def workspace_hooks_path(root = Dir.pwd)
        File.join(File.expand_path(root), ".kward", "hooks.json")
      end

      def trusted_workspace_hooks_path
        File.join(config_dir, "trusted_workspace_hooks.json")
      end

      # Returns a fresh default config suitable for first-run persistence.
      #
      # @return [Hash] deep-mutable config defaults
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
            "agent" => {},
            "runners" => {},
            "auto_indent" => true,
            "auto_close_pairs" => true,
            "soft_wrap" => true,
            "bar_cursor" => true,
            "line_numbers" => "absolute",
            "diff_view" => "auto"
          },
          "overlay" => DEFAULT_OVERLAY_SETTINGS.dup,
          "project_browser" => {
            "icons" => "off"
          },
          "web_search" => {
            "enabled" => true,
            "provider" => "auto",
            "allow_model_providers" => false
          },
          "updates" => {
            "check" => true
          },
          "sessions" => {
            "auto_resume" => false
          },
          "skills" => {
            "trust_project" => false
          },
          "enforce_workspace_agents_file" => false,
          "system_prompt" => {
            "include_principles" => true
          },
          "mcpServers" => {},
          "transports" => {},
          "tools" => {
            "workspace_guardrails" => true
          },
          "permissions" => {
            "enabled" => false,
            "mode" => "ask"
          },
          "sandbox" => {
            "mode" => "off",
            "network" => "deny",
            "writable_roots" => [],
            "protect_git_metadata" => true
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

      def model_catalog_cache_path(provider_id)
        provider = provider_id.to_s.gsub(/[^a-z0-9_-]/i, "_")
        raise ArgumentError, "Provider id must be a non-empty string" if provider.empty?

        File.join(cache_dir, "models", "#{provider}.json")
      end

      def update_check_cache_path
        File.join(cache_dir, "update_check.json")
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

        config = JSON.parse(File.read(path))
        return config if config.is_a?(Hash)

        raise ConfigError.new(path: path, format: "JSON", detail: "top-level value must be an object")
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

      def read_kwsh_config
        config = {
          shell: Kwsh::DEFAULT_SHELL,
          timeout_seconds: Kwsh::DEFAULT_TIMEOUT_SECONDS,
          max_output_bytes: Kwsh::DEFAULT_MAX_OUTPUT_BYTES,
          history_limit: Kwsh::DEFAULT_HISTORY_LIMIT,
          env: {},
          aliases: {}
        }
        rc_config = read_kwshrc_config
        config[:env].merge!(rc_config[:env])
        config[:aliases].merge!(rc_config[:aliases])
        config
      end

      def read_kwshrc_config(paths = kwshrc_paths, env: ENV.to_h)
        Kwshrc.read(paths, env: env)
      rescue Kwshrc::ParseError => e
        raise "Invalid kwshrc config: #{e.message}"
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
    end
  end
end

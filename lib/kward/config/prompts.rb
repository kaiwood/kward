# Configuration prompts behavior.
module Kward
  module ConfigFiles
    module Prompts
      extend self

      def agents_prompt(config: read_config)
        return nil unless include_config_principles?(config)

        path = config_principles_path
        return read_prompt_file(path, "Kward principles file") if File.exist?(path)

        read_prompt_file(config_agents_path, "Kward AGENTS.md alias")
      end

      # Returns whether config-directory principles are included in normal system
      # prompt assembly. Replacement prompt files bypass all assembled sections.
      def include_config_principles?(config = read_config)
        settings = config["system_prompt"]
        return true unless settings.is_a?(Hash)

        settings["include_principles"] != false
      end

      # Returns the configured replacement system prompt path, or nil when normal
      # prompt assembly should be used. Relative paths are anchored to the config
      # directory so configuration remains portable with KWARD_CONFIG_PATH.
      def system_prompt_file_path(config = read_config)
        settings = config["system_prompt"]
        value = settings.is_a?(Hash) ? settings["file"].to_s.strip : ""
        return nil if value.empty?

        File.expand_path(value, config_dir)
      end

      # Returns the replacement system prompt text when configured. A configured
      # but unavailable file intentionally yields nil: callers must not fall back
      # to Kward's larger assembled prompt in replacement mode.
      def system_prompt_file(config = read_config)
        path = system_prompt_file_path(config)
        return nil unless path

        read_prompt_file(path, "custom system prompt file")
      end

      def replacement_system_prompt?(config = read_config)
        !system_prompt_file_path(config).nil?
      end

      # Returns a lightweight fingerprint for config-owned prompt sources. It is
      # used by active conversations to pick up prompt edits without a restart.
      def system_prompt_sources_fingerprint
        config = read_config
        paths = [config_path, system_prompt_file_path(config)]
        if include_config_principles?(config)
          paths << (File.exist?(config_principles_path) ? config_principles_path : config_agents_path)
        end

        paths.compact.map { |path| prompt_source_signature(path) }.join("\0")
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

      def prompt_source_signature(path)
        return "#{path}:missing" unless File.exist?(path)

        stat = File.stat(path)
        "#{path}:#{stat.size}:#{stat.mtime.to_f}"
      rescue StandardError
        "#{path}:unavailable"
      end

      def read_prompt_file(path, label)
        return nil unless File.exist?(path)

        size = File.size(path)
        if size > MAX_PROMPT_FILE_BYTES
          emit_warning "Warning: skipping #{label} #{path}: file too large (#{size} bytes; limit is #{MAX_PROMPT_FILE_BYTES} bytes)"
          return nil
        end

        File.read(path)
      rescue StandardError => e
        emit_warning "Warning: skipping #{label} #{path}: #{e.message}"
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

    end
  end
end

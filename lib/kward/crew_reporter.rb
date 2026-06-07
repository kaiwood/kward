require_relative "config_files"
require_relative "model_info"

module Kward
  class CrewReporter
    IDENTITY_PROMPT = "Who are you? Describe your persona or role in one to three concise sentences for an internal crew report. Do not include reasoning.".freeze

    Report = Struct.new(:status, :message, :summary, :personas, keyword_init: true) do
      def success?
        status == :ok
      end

      def output
        success? ? summary.to_s : message.to_s
      end
    end

    def initialize(client:, workspace_root:, model:, reasoning_effort:, config: ConfigFiles.read_config, now: Time.now)
      @client = client
      @workspace_root = workspace_root
      @model = model
      @reasoning_effort = reasoning_effort
      @config = config
      @now = now
    end

    def report(instructions: "")
      return Report.new(status: :unsupported, message: "Crew command requires OpenAI OAuth (Codex) provider.") unless codex_provider?

      entries = active_persona_entries
      return Report.new(status: :empty, message: "No active personas found.", personas: []) if entries.empty?

      personas = entries.map { |entry| ask_persona(entry) }
      Report.new(status: :ok, summary: crew_summary(personas), personas: personas)
    end

    private

    def codex_provider?
      @client.respond_to?(:current_provider) && @client.current_provider == "Codex"
    end

    def active_persona_entries
      personas = @config["personas"]
      return [] unless personas.is_a?(Hash)

      characters = ConfigFiles.crew_characters(personas)
      entries = []
      add_crew_persona_entry(entries, "default", ConfigFiles.resolved_persona_text(personas["default"], characters: characters))
      add_workspace_persona_entry(entries, personas["workspaces"], characters: characters)
      add_model_persona_entries(entries, personas["models"], characters: characters)
      entries
    end

    def add_workspace_persona_entry(entries, workspaces, characters: {})
      return unless workspaces.is_a?(Hash)

      root = ConfigFiles.canonical_workspace_root(@workspace_root)
      workspaces.each do |path, key|
        next unless ConfigFiles.canonical_workspace_root(path) == root

        add_crew_persona_entry(entries, "workspace", ConfigFiles.resolved_persona_text(key, characters: characters), name: path)
        break
      end
    end

    def add_model_persona_entries(entries, models, characters: {})
      return unless models.is_a?(Hash)

      models.keys.sort.each do |model|
        add_crew_persona_entry(entries, "model", ConfigFiles.resolved_persona_text(models[model], characters: characters), name: model)
      end
    end

    def add_crew_persona_entry(entries, layer, value, name: nil)
      text = value.to_s.strip
      return if text.empty?

      entries << { layer: layer.to_s, name: name.to_s, prompt: text }
    end

    def ask_persona(entry)
      response = chat_without_reasoning(
        [
          { role: "system", content: entry[:prompt].to_s },
          { role: "user", content: IDENTITY_PROMPT }
        ],
        model: model_for_entry(entry)
      )
      persona_result(entry, status: :ok, summary: response.fetch("content", ""))
    rescue StandardError => e
      persona_result(entry, status: :failed, error: e.message)
    end

    def crew_summary(personas)
      lines = ["Crew Summary", "", "Active personas queried: #{personas.length}", ""]
      successful = personas.select { |persona| persona[:status] == :ok }
      failed = personas.select { |persona| persona[:status] == :failed }

      if successful.empty?
        lines << "No personas responded successfully."
      else
        lines << "## Confirmed identities"
        lines.concat(persona_table(successful) { |persona| persona[:summary].to_s.strip.empty? ? "(no response)" : persona[:summary].to_s.strip })
      end

      if failed.any?
        lines << ""
        lines << "## Errors"
        lines.concat(persona_table(failed) { |persona| persona[:error].to_s })
      end

      lines.join("\n")
    end

    def persona_table(personas)
      rows = personas.map do |persona|
        [persona_label(persona), persona_model_value(persona), yield(persona)]
      end
      headers = ["Persona", "Model", "Identity"]
      widths = headers.each_with_index.map do |header, index|
        ([header.length] + rows.map { |row| row[index].length }).max
      end
      table = [format_table_row(headers, widths), format_table_row(widths.map { |width| "-" * width }, widths)]
      table.concat(rows.map { |row| format_table_row(row, widths) })
      table
    end

    def format_table_row(cells, widths)
      padded = cells.each_with_index.map { |cell, index| cell.ljust(widths[index]) }
      "| #{padded.join(" | ")} |"
    end

    def persona_result(entry, status:, summary: nil, error: nil)
      {
        layer: entry[:layer].to_s,
        name: entry[:name].to_s,
        prompt: entry[:prompt].to_s,
        model: model_for_entry(entry),
        status: status,
        summary: summary,
        error: error
      }.compact
    end

    def persona_label(persona)
      name = persona[:name].to_s.strip
      name.empty? ? persona[:layer].to_s : "#{persona[:layer]} (#{name})"
    end

    def persona_model_label(persona)
      model = persona_model_value(persona)
      model.empty? ? "" : " [model: #{model}]"
    end

    def persona_model_value(persona)
      return "" if persona[:layer].to_s == "default"

      persona[:model].to_s
    end

    def model_for_entry(entry)
      entry[:layer].to_s == "model" && !entry[:name].to_s.empty? ? entry[:name].to_s : @model
    end

    def chat_without_reasoning(messages, model:)
      if chat_accepts_keyword?(:reasoning)
        @client.chat(messages, model: model, reasoning: false)
      elsif chat_accepts_keyword?(:model)
        @client.chat(messages, model: model)
      else
        @client.chat(messages)
      end
    end

    def chat_accepts_keyword?(keyword)
      @chat_parameters ||= @client.method(:chat).parameters
      @chat_parameters.any? do |type, name|
        type == :keyrest || ((type == :key || type == :keyreq) && name == keyword)
      end
    end
  end
end

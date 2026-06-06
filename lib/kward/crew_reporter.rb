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
      summary = summarize_personas(personas, instructions: instructions)
      summary = fallback_summary(personas) if summary.to_s.strip.empty?
      Report.new(status: :ok, summary: summary, personas: personas)
    end

    private

    def codex_provider?
      @client.respond_to?(:current_provider) && @client.current_provider == "Codex"
    end

    def active_persona_entries
      ConfigFiles.persona_entries(
        workspace_root: @workspace_root,
        model: @model,
        reasoning_effort: @reasoning_effort,
        now: @now,
        config: @config,
        include_reasoning: false
      )
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

    def summarize_personas(personas, instructions: "")
      response = chat_without_reasoning(
        [
          { role: "system", content: summary_system_prompt(instructions) },
          { role: "user", content: summary_user_prompt(personas) }
        ],
        model: @model
      )
      response.fetch("content", "")
    end

    def summary_system_prompt(instructions)
      prompt = "You are a concise assistant. Summarize persona identities in a compact Markdown crew report. Do not include reasoning."
      extra = instructions.to_s.strip
      extra.empty? ? prompt : "#{prompt} Additional instruction: #{extra}"
    end

    def summary_user_prompt(personas)
      lines = personas.map do |persona|
        label = persona_label(persona)
        if persona[:status] == :ok
          "- #{label}: #{persona[:summary].to_s.strip}"
        else
          "- #{label}: ERROR: #{persona[:error]}"
        end
      end
      ["These are the active persona identity results:", "", lines.join("\n")].join("\n")
    end

    def fallback_summary(personas)
      lines = ["Crew Summary", "", "Active personas queried: #{personas.length}", ""]
      successful = personas.select { |persona| persona[:status] == :ok }
      failed = personas.select { |persona| persona[:status] == :failed }

      if successful.empty?
        lines << "No personas responded successfully."
      else
        lines << "## Confirmed identities"
        successful.each do |persona|
          summary = persona[:summary].to_s.strip
          lines << "- #{persona_label(persona)}: #{summary.empty? ? "(no response)" : summary}"
        end
      end

      if failed.any?
        lines << ""
        lines << "## Errors"
        failed.each { |persona| lines << "- #{persona_label(persona)}: #{persona[:error]}" }
      end

      lines.join("\n")
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

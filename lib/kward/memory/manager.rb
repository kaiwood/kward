require "fileutils"
require "json"
require "securerandom"
require "set"
require "time"
require_relative "../config_files"
require_relative "../message_access"
require_relative "../model/client"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Memory subsystem for core, soft, session, and retrieval state.
  module Memory
    # Manages Kward's opt-in structured memory store.
    #
    # Core memories are explicit, high-trust instructions. Soft memories are
    # confidence-scored contextual hints. Session memory is handled by session
    # persistence, while this manager owns global/workspace JSON and JSONL files
    # plus the audit event log.
    class Manager
      CORE_LIMIT = 6
      SOFT_LIMIT = 6
      DEFAULT_SOFT_TTL_DAYS = 60
      DEFAULT_SOFT_CONFIDENCE = 0.65
      EMOTIONAL_PATTERN = /\b(love|loves|romantic|intimate|dependency|depend on me|need me|flirty|crush)\b/i

      # Details for the most recent retrieval, used by `/memory why`.
      attr_reader :last_retrieval

      def self.for_config_dir(config_dir, now: nil)
        new(
          config_path: File.join(config_dir, "config.json"),
          core_path: File.join(config_dir, "memory", "core.json"),
          soft_path: File.join(config_dir, "memory", "soft.jsonl"),
          events_path: File.join(config_dir, "memory", "events.jsonl"),
          now: now
        )
      end

      # Creates an object for memory storage and retrieval.
      def initialize(config_path: ConfigFiles.config_path, core_path: ConfigFiles.memory_core_path, soft_path: ConfigFiles.memory_soft_path, events_path: ConfigFiles.memory_events_path, now: nil)
        @config_path = config_path
        @core_path = core_path
        @soft_path = soft_path
        @events_path = events_path
        @now = now
        @last_retrieval = nil
      end

      # @return [Boolean] whether memory prompt injection is enabled
      def enabled?
        config = ConfigFiles.read_config(@config_path)
        memory = config["memory"]
        memory.is_a?(Hash) && memory["enabled"] == true
      rescue StandardError
        false
      end

      def enable
        config = ConfigFiles.read_config(@config_path)
        memory = config["memory"].is_a?(Hash) ? config["memory"].dup : {}
        memory["enabled"] = true
        config["memory"] = memory
        ConfigFiles.write_config(config, @config_path)
        ensure_storage!
        append_event("enable", {})
        true
      end

      def disable
        config = ConfigFiles.read_config(@config_path)
        memory = config["memory"].is_a?(Hash) ? config["memory"].dup : {}
        memory["enabled"] = false
        config["memory"] = memory
        ConfigFiles.write_config(config, @config_path)
        append_event("disable", {})
        true
      end

      def auto_summary_enabled?
        config = ConfigFiles.read_config(@config_path)
        memory = config["memory"]
        memory.is_a?(Hash) && memory["auto_summary"] == true
      rescue StandardError
        false
      end

      def auto_summary_enabled=(value)
        set_auto_summary(value)
      end

      def set_auto_summary(value)
        config = ConfigFiles.read_config(@config_path)
        memory = config["memory"].is_a?(Hash) ? config["memory"].dup : {}
        enabled = value ? true : false
        previous = memory["auto_summary"] == true
        if enabled
          memory["auto_summary"] = true
        else
          memory.delete("auto_summary")
        end
        config["memory"] = memory
        ConfigFiles.write_config(config, @config_path)
        append_event(enabled ? "auto_summary_enable" : "auto_summary_disable", {}) unless previous == enabled
        auto_summary_enabled?
      end

      def auto_summary_enable
        set_auto_summary(true)
      end

      def auto_summary_disable
        set_auto_summary(false)
      end

      # Stores an explicit high-trust memory.
      #
      # @param text [String] memory text
      # @param scope [String] `global` or `workspace:<path>` scope
      # @param tags [Array<String>] searchable tags
      # @return [Hash] stored memory record
      def add_core(text, scope: "global", tags: [], source: "explicit_user_instruction", pinned: true)
        record = {
          "id" => next_id("core", core_memories.map { |item| item["id"] }),
          "text" => clean_text(normalize_memory_text(text)),
          "scope" => clean_scope(scope),
          "tags" => clean_tags(tags),
          "created_at" => timestamp,
          "updated_at" => timestamp,
          "source" => source,
          "pinned" => pinned ? true : false
        }
        raise ArgumentError, "Memory text cannot be empty" if record["text"].empty?

        memories = core_memories
        memories << record
        write_core(memories)
        append_event("add", event_ref(record, layer: "core"))
        record
      end

      # Stores a contextual hint with confidence and optional expiry.
      #
      # @param text [String] memory text
      # @param scope [String] `global` or `workspace:<path>` scope
      # @param tags [Array<String>] searchable tags
      # @param confidence [Numeric] confidence clamped between 0.0 and 1.0
      # @param ttl_days [Integer, nil] time-to-live in days
      # @return [Hash] stored memory record
      def add_soft(text, scope: "global", tags: [], confidence: DEFAULT_SOFT_CONFIDENCE, ttl_days: DEFAULT_SOFT_TTL_DAYS, source: "manual")
        record = {
          "id" => next_id("soft", soft_memories(include_inactive: true).map { |item| item["id"] }),
          "text" => clean_text(normalize_memory_text(text)),
          "scope" => clean_scope(scope),
          "tags" => clean_tags(tags),
          "confidence" => [[confidence.to_f, 0.0].max, 1.0].min,
          "hits" => 0,
          "created_at" => timestamp,
          "updated_at" => timestamp,
          "last_seen_at" => timestamp,
          "ttl_days" => ttl_days.to_i <= 0 ? DEFAULT_SOFT_TTL_DAYS : ttl_days.to_i,
          "source" => source,
          "status" => "active"
        }
        raise ArgumentError, "Memory text cannot be empty" if record["text"].empty?
        raise ArgumentError, "Refusing to persist emotional or dependency-forming memory automatically" if source == "inferred" && unsafe_soft_text?(record["text"])

        append_soft(record)
        append_event("add", event_ref(record, layer: "soft"))
        record
      end

      def promote_memory(id)
        id = id.to_s
        core = core_memories.find { |item| item["id"] == id }
        return promote_core_to_global(core) if core

        promote_soft_to_core(id)
      end

      def promote_soft_to_core(id)
        soft = soft_memories.find { |item| item["id"] == id.to_s }
        raise ArgumentError, "Unknown active soft memory or workspace core memory: #{id}" unless soft

        core = add_core(soft["text"], scope: soft["scope"], tags: soft["tags"], source: "promoted_soft_memory", pinned: true)
        forget_memory(id)
        append_event("promote", { "from_id" => soft["id"], "to_id" => core["id"] })
        core
      end

      def relax_core(id, workspace_root: Dir.pwd)
        id = id.to_s
        memories = core_memories
        core = memories.find { |item| item["id"] == id }
        raise ArgumentError, "Unknown core memory: #{id}" unless core
        raise ArgumentError, "Only global core memories can be relaxed" unless core["scope"] == "global"

        core["scope"] = workspace_scope(workspace_root)
        core["updated_at"] = timestamp
        write_core(memories)
        append_event("relax", event_ref(core, layer: "core"))
        core
      end

      def forget_memory(id)
        id = id.to_s
        memories = core_memories
        if memories.any? { |item| item["id"] == id }
          write_core(memories.reject { |item| item["id"] == id })
          append_event("forget", { "id" => id, "layer" => "core" })
          return true
        end

        records = soft_memories(include_inactive: true)
        found = false
        records.each do |item|
          next unless item["id"] == id && item["status"] != "forgotten"

          item["text"] = "[forgotten]"
          item["tags"] = []
          item["confidence"] = 0.0
          item["hits"] = 0
          item["status"] = "forgotten"
          item["updated_at"] = timestamp
          found = true
        end
        if found
          write_soft(records)
          append_event("forget", { "id" => id, "layer" => "soft" })
        end
        found
      end

      def list(include_inactive: false)
        { "core" => core_memories, "soft" => soft_memories(include_inactive: include_inactive) }
      end

      def hierarchy(workspace_root: Dir.pwd, include_inactive: false)
        workspace = workspace_scope(workspace_root)
        core = core_memories
        {
          "global_core" => core.select { |item| item["scope"] == "global" },
          "workspace_core" => core.select { |item| item["scope"] == workspace },
          "workspace_soft" => soft_memories(include_inactive: include_inactive).select { |item| item["scope"] == workspace }
        }
      end

      def inspect_memory
        list(include_inactive: true).merge("enabled" => enabled?, "paths" => paths)
      end

      # Selects bounded core and soft memories relevant to an interactive turn.
      #
      # Retrieval is scoped to global and workspace memories, prefers core
      # memories, and scores soft memories by text/tag overlap, confidence, and
      # expiry.
      #
      # @param input [String] current user input
      # @param workspace_root [String] active workspace root
      # @return [Hash] retrieval result for prompt injection and explanation
      def retrieve_relevant(input:, workspace_root: Dir.pwd, max_core: CORE_LIMIT, max_soft: SOFT_LIMIT)
        unless enabled?
          @last_retrieval = { "enabled" => false, "core" => [], "soft" => [], "reasons" => [] }
          return @last_retrieval
        end

        scopes = scopes_for(workspace_root)
        workspace = workspace_scope(workspace_root)
        terms = terms_for(input)
        core = ranked_core_memories(workspace).first(max_core)
        core_reasons = core.map { |item| reason_for(item, layer: "core", score: 1.0, reasons: ["scope match", "core memories are preferred"]) }

        soft_records_all = soft_memories(include_inactive: true)
        soft_scored = soft_records_all.filter_map do |item|
          next unless item["status"] == "active"
          next unless item["scope"] == workspace
          next if expired?(item)

          score, reasons = soft_score(item, terms)
          next if score <= 0

          [item, score, reasons]
        end
        soft = soft_scored.sort_by { |item, score, _reasons| [-score, -item["confidence"].to_f, item["id"].to_s] }.first(max_soft)
        soft_records = soft.map(&:first)
        touch_soft_records(soft_records_all, soft_records)
        soft_reasons = soft.map { |item, score, reasons| reason_for(item, layer: "soft", score: score, reasons: reasons) }

        @last_retrieval = {
          "enabled" => true,
          "scopes" => scopes,
          "core" => core,
          "soft" => soft_records,
          "reasons" => core_reasons + soft_reasons
        }
        append_event("retrieve", { "core_ids" => core.map { |item| item["id"] }, "soft_ids" => soft_records.map { |item| item["id"] }, "scopes" => scopes })
        @last_retrieval
      end

      # @return [Hash] explanation data for the most recent retrieval
      def explain_retrieval
        @last_retrieval || { "enabled" => enabled?, "core" => [], "soft" => [], "reasons" => [], "message" => "No memory retrieval has run yet." }
      end

      # Formats retrieved memories for system prompt injection.
      #
      # Keep this block compact and explicit: it is read by the model, shown in
      # transcripts, and explained by `/memory why`. Do not include inactive or
      # forgotten memories here; retrieval already decides the active set.
      def memory_block(retrieval)
        core = Array(retrieval["core"])
        soft = Array(retrieval["soft"])
        return nil if core.empty? && soft.empty?

        global_core = core.select { |item| item["scope"] == "global" }
        workspace_core = core.reject { |item| item["scope"] == "global" }

        lines = ["<kward_memory>"]
        unless global_core.empty?
          lines << "Global Core Memories:"
          global_core.each { |item| lines << "- [#{item["id"]}] #{item["text"]}" }
          lines << ""
        end
        unless workspace_core.empty?
          lines << "Workspace Core Memories:"
          workspace_core.each { |item| lines << "- [#{item["id"]}] #{item["text"]}" }
          lines << ""
        end
        unless soft.empty?
          lines << "Workspace Soft Memories:"
          soft.each { |item| lines << "- [#{item["id"]}] #{item["text"]}" }
          lines << ""
        end
        lines << "Rules:"
        lines << "- Core memories override soft memories."
        lines << "- Soft memories are contextual hints, not guaranteed facts."
        lines << "</kward_memory>"
        lines.join("\n")
      end

      # Infers bounded session/workspace soft memories from a conversation.
      #
      # This is best-effort and intentionally conservative. It may use an LLM when
      # configured, but failures fall back to heuristic text or no-op behavior so
      # memory summarization never blocks normal session flow.
      def summarize_conversation(conversation, client: nil)
        text = messages_for_summarization(conversation).map { |message| MessageAccess.content(message) }.compact.join("\n")
        existing_texts = Array(conversation.session_memories).map { |memory| memory["text"] }
        records = infer_soft_from_text(text, workspace_root: conversation.workspace_root, client: client, existing_texts: existing_texts)
        conversation.session_memories.concat(records.map { |record| record.slice("id", "text", "scope", "tags") }) if conversation.session_memories.respond_to?(:concat)
        records
      end

      def infer_soft_from_text(text, workspace_root: Dir.pwd, client: nil, existing_texts: [])
        candidates = heuristic_candidates(text)
        existing_set = Set.new(existing_texts.map { |t| normalize_for_comparison(t) })
        candidates.filter_map do |candidate|
          summarized = summarize_text(candidate, client: client)
          normalized = normalize_for_comparison(summarized)
          # Skip if this text already exists in provided list or existing soft memories
          next if existing_set.include?(normalized)
          next if soft_memories.any? { |m| normalize_for_comparison(m["text"]) == normalized }

          add_soft(summarized, scope: workspace_scope(workspace_root), tags: ["workflow"], confidence: 0.55, source: "inferred")
        end
      end

      def summarize_text(text, client: nil)
        summarizer_client = client
        unless summarizer_client
          return text unless should_use_llm_summarization?

          summarizer_client = default_client
        end

        summary = llm_summarize(summarizer_client, text)
        summary.empty? ? text : summary
      rescue StandardError
        text
      end

      def should_use_llm_summarization?
        # Check if we have valid credentials to make LLM calls
        client = default_client
        return false unless client

        token = client.instance_variable_get(:@openai_access_token) ||
                       client.instance_variable_get(:@openrouter_api_key) ||
                       client.send(:github_access_token)
        token.to_s.length > 10
      rescue StandardError
        false
      end

      def default_client
        @default_client ||= Kward::Client.new
      rescue StandardError
        nil
      end

      def llm_summarize(client, text)
        messages = [
          { role: "system", content: <<~SYSTEM },
            You are a memory text reformulation assistant. Your task is to transform user-generated text into proper third-person descriptive memory statements.

            Rules:
            - Convert first-person statements ("I like", "we prefer") to third-person ("The captain likes", "The user prefers")
            - Remove conversational filler, preambles, and action descriptions
            - Keep only the factual preference or fact
            - Use "The captain" or "The user" as the subject for personal preferences
            - Preserve workflow-related technical preferences as-is
            - Keep the text concise (under 100 characters)
            - If the text is already a good memory statement, return it unchanged

            Examples:
            - "I like to eat the most important meal today: steak" → "The captain likes eating steak"
            - "We should prefer TDD for this project" → "Prefer TDD for this project"
            - "Remember that the user prefers minitest" → "The user prefers minitest"
            - "But first we need to remember that we are using TDD" → "Use TDD"
            - "The user usually asks for tests" → "The user usually asks for tests"
            - "Prefer evidence from code, tests, logs" → "Prefer evidence from code, tests, logs"
          SYSTEM
          { role: "user", content: "Reformulate this as a memory statement: #{text}" }
        ]

        response = client.chat(messages, max_tokens: 100, reasoning: false)
        content = response.dig("content") || response[:content]
        return text unless content

        content.strip
      rescue StandardError
        text
      end

      def paths
        { "core" => @core_path, "soft" => @soft_path, "events" => @events_path }
      end

      private

      def messages_for_summarization(conversation)
        conversation.messages.select { |message| MessageAccess.role(message) == "user" }
      end

      def ensure_storage!
        FileUtils.mkdir_p(File.dirname(@core_path), mode: 0o700)
        write_core([]) unless File.exist?(@core_path)
        File.open(@soft_path, File::WRONLY | File::CREAT | File::APPEND, 0o600) {} unless File.exist?(@soft_path)
        File.open(@events_path, File::WRONLY | File::CREAT | File::APPEND, 0o600) {} unless File.exist?(@events_path)
        [@core_path, @soft_path, @events_path].each { |path| File.chmod(0o600, path) if File.exist?(path) }
      end

      def core_memories
        return [] unless File.exist?(@core_path)

        data = JSON.parse(File.read(@core_path))
        data.is_a?(Array) ? data : Array(data["memories"])
      rescue JSON::ParserError
        raise "Invalid Kward core memory JSON: #{@core_path}"
      end

      def write_core(records)
        ensure_parent(@core_path)
        File.open(@core_path, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |file|
          file.write(JSON.pretty_generate(records))
          file.write("\n")
        end
        File.chmod(0o600, @core_path)
      end

      def soft_memories(include_inactive: false)
        return [] unless File.exist?(@soft_path)

        File.readlines(@soft_path, chomp: true).filter_map do |line|
          next if line.strip.empty?

          JSON.parse(line)
        rescue JSON::ParserError
          nil
        end.select { |item| include_inactive || item["status"] == "active" }
      end

      def append_soft(record)
        ensure_parent(@soft_path)
        File.open(@soft_path, File::WRONLY | File::CREAT | File::APPEND, 0o600) do |file|
          file.write(JSON.generate(record))
          file.write("\n")
        end
        File.chmod(0o600, @soft_path)
      end

      def write_soft(records)
        ensure_parent(@soft_path)
        File.open(@soft_path, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |file|
          records.each do |record|
            file.write(JSON.generate(record))
            file.write("\n")
          end
        end
        File.chmod(0o600, @soft_path)
      end

      def append_event(type, payload)
        ensure_parent(@events_path)
        event = { "type" => type, "timestamp" => timestamp }.merge(payload)
        File.open(@events_path, File::WRONLY | File::CREAT | File::APPEND, 0o600) do |file|
          file.write(JSON.generate(event))
          file.write("\n")
        end
        File.chmod(0o600, @events_path)
      end

      def ensure_parent(path)
        FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
      end

      def next_id(prefix, ids)
        number = ids.filter_map { |id| id.to_s[/\A#{Regexp.escape(prefix)}_(\d+)\z/, 1]&.to_i }.max.to_i + 1
        format("%s_%03d", prefix, number)
      end

      def timestamp
        (@now || Time.now.utc).utc.iso8601(3)
      end

      def clean_text(text)
        text.to_s.strip.gsub(/[\r\n]+/, " ")
      end

      def normalize_for_comparison(text)
        text.to_s.strip.gsub(/\s+/, " ")
      end

      def clean_scope(scope)
        value = scope.to_s.strip
        value.empty? ? "global" : value
      end

      def clean_tags(tags)
        Array(tags).flat_map { |tag| tag.to_s.split(/[,\s]+/) }.map(&:strip).reject(&:empty?).uniq.first(10)
      end

      def scopes_for(workspace_root)
        ["global", workspace_scope(workspace_root)]
      end

      def ranked_core_memories(workspace)
        memories = core_memories
        memories.select { |item| item["scope"] == "global" } + memories.select { |item| item["scope"] == workspace }
      end

      def promote_core_to_global(core)
        raise ArgumentError, "Only workspace core memories can be promoted" if core["scope"] == "global"
        raise ArgumentError, "Only workspace core memories can be promoted" unless core["scope"].to_s.start_with?("workspace:")

        memories = core_memories
        record = memories.find { |item| item["id"] == core["id"] }
        record["scope"] = "global"
        record["updated_at"] = timestamp
        write_core(memories)
        append_event("promote", event_ref(record, layer: "core"))
        record
      end

      def workspace_scope(workspace_root)
        "workspace:#{ConfigFiles.canonical_workspace_root(workspace_root)}"
      end

      def terms_for(input)
        input.to_s.downcase.scan(/[a-z0-9_\-]{3,}/).uniq
      end

      def soft_score(item, terms)
        reasons = ["scope match"]
        text_terms = terms_for(item["text"])
        overlap = terms & text_terms
        tags = Array(item["tags"]).map(&:to_s)
        tag_overlap = terms & tags
        return [0, reasons] if overlap.empty? && tag_overlap.empty?

        score = item["confidence"].to_f
        if overlap.any?
          score += [overlap.length * 0.15, 0.45].min
          reasons << "text overlap: #{overlap.first(5).join(", ")}"
        end
        if tag_overlap.any?
          score += 0.25
          reasons << "tag overlap: #{tag_overlap.join(", ")}"
        end
        reasons << "confidence #{format("%.2f", item["confidence"].to_f)}"
        [score, reasons]
      end

      def touch_soft_records(all_records, selected_records)
        ids = Set.new(selected_records.map { |item| item["id"] })
        return if ids.empty?

        now = timestamp
        changed = false
        all_records.each do |item|
          next unless ids.include?(item["id"])
          next unless item["status"] == "active"

          item["hits"] = item["hits"].to_i + 1
          item["last_seen_at"] = now
          item["updated_at"] = now
          changed = true
        end
        write_soft(all_records) if changed
      end

      def reason_for(item, layer:, score:, reasons:)
        { "id" => item["id"], "layer" => layer, "score" => score.round(3), "reasons" => reasons }
      end

      def expired?(item)
        ttl = item["ttl_days"].to_i
        return false if ttl <= 0

        last_seen = Time.parse(item["last_seen_at"].to_s)
        last_seen < (@now || Time.now.utc).utc - (ttl * 86_400)
      rescue StandardError
        false
      end

      def event_ref(record, layer:)
        { "id" => record["id"], "layer" => layer, "scope" => record["scope"], "tags" => record["tags"] }
      end

      def heuristic_candidates(text)
        lines = text.to_s.split(/[
.;]/).map(&:strip)
        lines.filter_map do |line|
          # Skip lines that look like memory display output (e.g., "- soft_001 [workspace:...] text")
          next if line.match?(/\A-\s*(core|soft)_\d+\s/)

          candidate = explicit_memory_candidate(line) || personal_memory_candidate(line)
          next if candidate.to_s.empty? || unsafe_soft_text?(candidate)

          clean_text(candidate)
        end.reject(&:empty?).uniq.first(5)
      end
      def explicit_memory_candidate(line)
        line.to_s[/\b(?:important information|remember this|please remember|note that)\s*:\s*(.+)\z/i, 1]
      end

      def personal_memory_candidate(line)
        text = line.to_s.strip
        # Skip URL fragments like "com/kaiwood/kward]..."
        return nil if text.match?(/\A[\w\/\.]+\]/)
        return nil unless text.match?(/\b(?:i|we|user|captain)\b/i)
        return nil unless text.match?(/\b(?:prefer|prefers|usually|always|workflow|project|use|uses|avoid|avoids|like|likes)\b/i)

        text
      end

      def unsafe_soft_text?(text)
        text.to_s.match?(EMOTIONAL_PATTERN)
      end

      def normalize_memory_text(text)
        normalized = text.to_s.strip

        # Strip workspace context if it appears at the start: [workspace:/path/to/dir]
        normalized = normalized.sub(/\A\[workspace:[^\]]*\]\s*/, '')
        # Also strip any remaining fragment like "Com/kaiwood/kward]" that may be left over from malformed input
        normalized = normalized.sub(/\A[\w\/\-\.]+\]\s*/, '') if normalized.match?(/\A[\w\/\-\.]+\]/)

        # Only apply aggressive transformations if we detect a preamble pattern
        has_preamble = normalized.match?(/\b(?:But\s+first|Remember\s+that|Please\s+remember|Note\s+that|I\s+should\s+remember)\b/i)

        # Remove verbose preambles
        preamble_patterns = [
          /\bBut\s+first\s+we\s+always\s+need\s+to\s+remember\s+that\s+/i,
          /\bRemember\s+that\s+/i,
          /\bPlease\s+remember\s+to\s+/i,
          /\bNote\s+that\s+/i,
          /\bI\s+should\s+remember\s+that\s+/i
        ]

        if has_preamble
          preamble_patterns.each do |pattern|
            normalized = normalized.sub(pattern) { "" }
          end

          # Mapping from gerund (-ing form) to imperative base form
          gerund_map = {
            "using" => "Use",
            "testing" => "Test",
            "relying" => "Rely",
            "preferring" => "Prefer",
            "avoiding" => "Avoid",
            "keeping" => "Keep",
            "writing" => "Write",
            "reading" => "Read",
            "checking" => "Check",
            "reviewing" => "Review",
            "validating" => "Validate"
          }

          # Transform "we are X" to imperative: "we are using" -> "Use"
          normalized = normalized.sub(/\bwe\s+are\s+(\w+ing)\b/i) do |_match|
            gerund = Regexp.last_match(1).downcase
            gerund_map[gerund] || gerund.capitalize
          end

          # Transform "we should X" to imperative: "we should prefer" -> "Prefer"
          normalized = normalized.sub(/\bwe\s+should\s+(\w+)\b/i) do |_match|
            word = Regexp.last_match(1)
            word.capitalize
          end

          # Remove remaining "we" or "I" at the line start
          normalized = normalized.sub(/\b(we|i)\s+/i, '')
        end

        # Capitalize first letter if lowercase
        normalized = normalized.sub(/\A([a-z])/) { |m| m.upcase }

        normalized.strip
      end
    end
  end
end

require "fileutils"
require "json"
require "securerandom"
require "time"
require_relative "config_files"
require_relative "conversation"
require_relative "message_access"
require_relative "rpc/tool_event_normalizer"
require_relative "tool_call"
require_relative "workspace"

module Kward
  class SessionStore
    VERSION = 1

    SessionInfo = Struct.new(:id, :path, :cwd, :created_at, :modified_at, :name, :first_message, :message_count, :parent_id, :parent_path, :depth, :is_last, :ancestor_continues, keyword_init: true)

    class Session
      attr_reader :id, :path, :cwd, :created_at, :parent_id, :parent_path
      attr_accessor :name

      def initialize(store:, id:, path:, cwd:, created_at:, name: nil, parent_id: nil, parent_path: nil)
        @store = store
        @id = id
        @path = path
        @cwd = cwd
        @created_at = created_at
        @name = name
        @parent_id = parent_id
        @parent_path = parent_path
      end

      def attach(conversation)
        conversation.on_append = lambda { |message| append_message(message) }
        conversation.on_compact = lambda { |message| compact(message) }
        conversation.on_tool_execution = lambda { |tool_call, content| append_tool_execution(tool_call, content) }
        self
      end

      def append_message(message)
        @store.append_record(@path, {
          type: "message",
          timestamp: Time.now.utc.iso8601(3),
          message: message
        })
      end

      def compact(message)
        @store.append_record(@path, {
          type: "compaction",
          timestamp: Time.now.utc.iso8601(3),
          message: message
        })
      end

      def append_tool_execution(tool_call, content)
        @store.append_record(@path, RPC::ToolEventNormalizer.new(tool_call, content: content).execution_record)
      end

      def update_memory_state(session_memories:, last_retrieval: nil)
        @store.append_record(@path, {
          type: "memory_state",
          timestamp: Time.now.utc.iso8601(3),
          sessionMemories: Array(session_memories),
          lastRetrieval: last_retrieval
        })
      end

      def rename(name)
        @name = name.to_s.strip.empty? ? nil : name.to_s.strip
        @store.append_record(@path, {
          type: "session_info",
          timestamp: Time.now.utc.iso8601(3),
          name: @name
        })
      end

      def update_runtime(model:, reasoning_effort:)
        @store.append_record(@path, {
          type: "session_info",
          timestamp: Time.now.utc.iso8601(3),
          name: @name,
          model: model.to_s,
          reasoningEffort: reasoning_effort.to_s
        }.delete_if { |_key, value| value.to_s.empty? })
      end

      def delete_if_unused
        @store.delete_unused_session(self)
      end
    end

    def initialize(config_dir: ConfigFiles.config_dir, cwd: Dir.pwd)
      @config_dir = config_dir
      @cwd = File.expand_path(cwd)
    end

    attr_reader :cwd

    def create(model: nil, reasoning_effort: nil, parent_id: nil, parent_path: nil)
      dir = session_dir
      FileUtils.mkdir_p(dir, mode: 0o700)
      created_at = Time.now.utc
      id = SecureRandom.uuid
      path = File.join(dir, "#{created_at.iso8601(3).tr(':', '-')}_#{id}.jsonl")
      header = {
        type: "session",
        version: VERSION,
        id: id,
        timestamp: created_at.iso8601(3),
        cwd: @cwd,
        model: model.to_s,
        reasoningEffort: reasoning_effort.to_s,
        parentId: parent_id.to_s,
        parentPath: parent_path.to_s
      }.delete_if { |_key, value| value.to_s.empty? }

      File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
        file.write(JSON.generate(header))
        file.write("\n")
      end
      File.chmod(0o600, path)

      Session.new(store: self, id: id, path: path, cwd: @cwd, created_at: created_at, parent_id: parent_id, parent_path: parent_path)
    end

    def create_from_conversation(conversation, parent_session: nil)
      session = create(model: conversation.model, reasoning_effort: conversation.reasoning_effort, parent_id: parent_session&.id, parent_path: parent_session&.path)
      persisted_messages(conversation).each { |message| session.append_message(message) }
      session.attach(conversation)
      session
    end

    def create_independent_from_conversation(conversation, parent_session: nil)
      create_independent_from_messages(
        persisted_messages(conversation),
        read_paths: Array(conversation.read_paths),
        model: conversation.model,
        reasoning_effort: conversation.reasoning_effort,
        parent_session: parent_session
      )
    end

    def create_independent_from_messages(messages, read_paths: [], model: nil, reasoning_effort: nil, parent_session: nil)
      session = create(model: model, reasoning_effort: reasoning_effort, parent_id: parent_session&.id, parent_path: parent_session&.path)
      persisted = deep_copy(messages)
      persisted.each { |message| session.append_message(message) }
      conversation = Conversation.new(messages: deep_copy(persisted), read_paths: read_paths, workspace_root: @cwd, model: model, reasoning_effort: reasoning_effort)
      session.attach(conversation)
      [session, conversation]
    end

    def session_location(path)
      resolved_path = resolve_session_path(path)
      records = records_from_file(resolved_path)
      header = session_header(records, resolved_path)
      { path: resolved_path, cwd: header["cwd"].to_s.empty? ? @cwd : header["cwd"].to_s }
    end

    def load(path, workspace: Workspace.new, model: nil, reasoning_effort: nil)
      resolved_path = resolve_session_path(path)
      records = records_from_file(resolved_path)
      header = session_header(records, resolved_path)

      messages = restored_messages(records)
      name = session_name(records)
      read_paths = restored_read_paths(messages, workspace)
      memory_state = restored_memory_state(records)

      runtime = session_runtime(records, header)
      conversation = Conversation.new(
        messages: messages,
        read_paths: read_paths,
        workspace_root: workspace.root,
        model: runtime["model"] || model,
        reasoning_effort: runtime["reasoningEffort"] || reasoning_effort,
        session_memories: memory_state["sessionMemories"],
        last_memory_retrieval: memory_state["lastRetrieval"]
      )
      conversation.mark_last_entry_compaction! if latest_record_type(records) == "compaction"
      session = Session.new(
        store: self,
        id: header["id"],
        path: resolved_path,
        cwd: header["cwd"].to_s,
        created_at: parse_time(header["timestamp"]) || File.mtime(resolved_path),
        name: name,
        parent_id: header["parentId"],
        parent_path: header["parentPath"]
      )
      session.attach(conversation)
      [session, conversation]
    end

    def recent(limit: 20)
      recent_sessions.first(limit)
    end

    def recent_tree(limit: 20)
      decorate_tree(recent_sessions.first(limit))
    end

    def delete_unused_session(session)
      path = session.path
      return false if session_named?(session)
      return false unless unused_session_file?(path)

      File.delete(path)
      true
    rescue StandardError
      false
    end

    def session_dir
      File.join(@config_dir, "sessions", self.class.safe_cwd(@cwd))
    end

    def append_record(path, record)
      File.open(path, "a", 0o600) do |file|
        file.write(JSON.generate(record))
        file.write("\n")
      end
    end

    def self.safe_cwd(cwd)
      "--#{File.expand_path(cwd).sub(%r{\A[/\\]}, "").gsub(%r{[/\\:]}, "-")}--"
    end

    private

    def resolve_session_path(path)
      expanded = path.to_s.start_with?("~/") ? File.join(Dir.home, path.to_s[2..]) : path.to_s
      resolved = File.expand_path(expanded, @cwd)
      raise "Session file not found: #{resolved}" unless File.file?(resolved)

      resolved
    end

    def records_from_file(path)
      File.readlines(path, chomp: true).filter_map do |line|
        JSON.parse(line)
      rescue JSON::ParserError
        nil
      end
    end

    def session_header(records, path)
      header = records.find { |record| record["type"] == "session" }
      raise "Invalid Kward session file: #{path}" unless header && header["id"].to_s != ""

      header
    end

    def session_named?(session)
      return true unless session.name.to_s.strip.empty?

      name = session_name(records_from_file(session.path))
      !name.to_s.strip.empty?
    rescue StandardError
      true
    end

    def unused_session_file?(path)
      records = strict_records_from_file(path)
      return false unless records

      header = records.find { |record| record["type"] == "session" }
      return false unless header && header["id"].to_s != ""

      records.none? do |record|
        next false unless record["type"] == "message"

        ["user", "assistant", "tool"].include?(message_role(record["message"] || {}))
      end
    end

    def latest_record_type(records)
      records.reverse_each do |record|
        type = record["type"]
        return type if ["message", "compaction"].include?(type)
      end
      nil
    end

    def session_name(records)
      record = records.select { |item| item["type"] == "session_info" }.last
      record ? record["name"] : nil
    end

    def restored_memory_state(records)
      records.reverse.find { |record| record["type"] == "memory_state" } || { "sessionMemories" => [], "lastRetrieval" => nil }
    end

    def session_runtime(records, header)
      result = {
        "model" => header["model"],
        "reasoningEffort" => header["reasoningEffort"]
      }
      records.each do |record|
        next unless record["type"] == "session_info"

        result["model"] = record["model"] if record.key?("model")
        result["reasoningEffort"] = record["reasoningEffort"] if record.key?("reasoningEffort")
      end
      result.delete_if { |_key, value| value.to_s.empty? }
    end

    def restored_messages(records)
      records.each_with_object([]) do |record, messages|
        message = record["message"]
        case record["type"]
        when "message"
          messages << message if message.is_a?(Hash)
        when "compaction"
          messages.replace(rebuilt_compacted_messages(message, messages)) if message.is_a?(Hash)
        end
      end
    end

    def rebuilt_compacted_messages(compaction_message, previous_messages)
      first_kept_entry_id = compaction_message["first_kept_entry_id"] || compaction_message["firstKeptEntryId"]
      return [compaction_message] if first_kept_entry_id.to_s.empty?

      messages = previous_messages.reject { |message| message_role(message) == "system" }
      previous_compaction_index = messages.rindex { |message| message_role(message) == "compactionSummary" }
      branch_messages = previous_compaction_index ? messages[previous_compaction_index..] : messages

      branch_index = branch_messages.each_with_index.find do |message, message_index|
        message["id"] == first_kept_entry_id || "message:#{message_index}" == first_kept_entry_id
      end&.last
      if branch_index
        kept = branch_messages[branch_index..]
      else
        index = messages.each_with_index.find do |message, message_index|
          message["id"] == first_kept_entry_id || "message:#{message_index}" == first_kept_entry_id
        end&.last
        kept = index ? messages[index..] : []
      end
      [compaction_message] + kept
    end

    def strict_records_from_file(path)
      File.readlines(path, chomp: true).map { |line| JSON.parse(line) }
    rescue JSON::ParserError
      nil
    end

    def recent_sessions
      Dir.glob(File.join(session_dir, "*.jsonl")).filter_map do |path|
        session_info(path)
      end.sort_by { |info| info.modified_at || Time.at(0) }.reverse
    end

    def decorate_tree(sessions)
      by_parent = Hash.new { |hash, key| hash[key] = [] }
      ids = sessions.map(&:id).to_h { |id| [id, true] }
      sessions.each do |session|
        parent_id = session.parent_id.to_s
        key = parent_id.empty? || !ids[parent_id] ? nil : parent_id
        by_parent[key] << session
      end
      by_parent.each_value { |children| children.sort_by! { |info| info.modified_at || Time.at(0) }.reverse! }

      result = []
      walk_tree(by_parent, nil, 0, [], result)
      result
    end

    def walk_tree(by_parent, parent_id, depth, ancestor_continues, result)
      children = by_parent[parent_id]
      children.each_with_index do |session, index|
        is_last = index == children.length - 1
        session.depth = depth
        session.is_last = is_last
        session.ancestor_continues = ancestor_continues.dup
        result << session
        child_ancestor_continues = depth.zero? ? [] : ancestor_continues + [!is_last]
        walk_tree(by_parent, session.id, depth + 1, child_ancestor_continues, result)
      end
    end

    def session_info(path)
      records = records_from_file(path)
      header = records.find { |record| record["type"] == "session" }
      return nil unless header && header["id"].to_s != ""

      messages = restored_messages(records)
      name = session_name(records)
      first_message = messages.find { |message| ["user", "compactionSummary"].include?(message_role(message)) }
      stats = File.stat(path)

      SessionInfo.new(
        id: header["id"],
        path: path,
        cwd: header["cwd"].to_s,
        created_at: parse_time(header["timestamp"]) || stats.mtime,
        modified_at: stats.mtime,
        name: name,
        first_message: first_message ? message_text(first_message) : "",
        message_count: messages.count { |message| ["user", "assistant", "tool", "toolResult", "compactionSummary"].include?(message_role(message)) },
        parent_id: header["parentId"],
        parent_path: header["parentPath"],
        depth: 0,
        is_last: true,
        ancestor_continues: []
      )
    rescue StandardError
      nil
    end

    def persisted_messages(conversation)
      conversation.messages.reject { |message| message_role(message) == "system" }.map { |message| deep_copy(message) }
    end

    def deep_copy(value)
      JSON.parse(JSON.generate(value))
    end

    def restored_read_paths(messages, workspace)
      tool_paths = {}
      read_paths = []

      messages.each do |message|
        role = message_role(message)
        if role == "assistant"
          tool_calls(message).each do |tool_call|
            next unless ToolCall.name(tool_call) == "read_file"

            path = ToolCall.value(ToolCall.arguments(tool_call), :path)
            tool_paths[ToolCall.id(tool_call)] = path if path
          end
        elsif role == "tool" && message_name(message) == "read_file"
          path = tool_paths[message_tool_call_id(message)]
          content = message_content(message).to_s
          read_paths << workspace.resolved_path(path) if path && !content.start_with?("Error:")
        end
      end

      read_paths
    end

    def tool_calls(message)
      MessageAccess.tool_calls(message)
    end

    def message_role(message)
      MessageAccess.role(message)
    end

    def message_name(message)
      MessageAccess.name(message)
    end

    def message_tool_call_id(message)
      MessageAccess.tool_call_id(message)
    end

    def message_content(message)
      MessageAccess.content(message)
    end

    def message_display_content(message)
      MessageAccess.display_content(message)
    end

    def message_text(message)
      return MessageAccess.summary(message).to_s.gsub(/\s+/, " ").strip.slice(0, 120) if message_role(message) == "compactionSummary"

      display_content = message_display_content(message)
      return display_content.to_s.gsub(/\s+/, " ").strip.slice(0, 120) unless display_content.nil?

      content = message_content(message)
      text = if content.is_a?(Array)
               content.filter_map { |part| part["text"] || part[:text] }.join(" ")
             else
               content.to_s
             end
      text.gsub(/\s+/, " ").strip.slice(0, 120)
    end

    def parse_time(value)
      Time.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end
  end
end

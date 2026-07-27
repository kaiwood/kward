require "fileutils"
require "digest"
require "json"
require "securerandom"
require "time"
require_relative "config_files"
require_relative "conversation"
require_relative "message_access"
require_relative "message_text"
require_relative "private_file"
require_relative "rpc/tool_event_normalizer"
require_relative "tools/tool_call"
require_relative "workspace"

# Namespace for the Kward CLI agent runtime.
module Kward
  # JSONL-backed persistence for CLI and RPC conversations.
  #
  # A session file is an append-only event log: a header record, message/tree
  # records, metadata changes, memory state, tool execution metadata, labels, and
  # branch navigation. `SessionStore` owns disk layout and reconstruction of a
  # `Conversation`; frontends own when to create, resume, clone, compact, or
  # delete sessions.
  #
  # The tree fields (`id`, `parentId`, leaf records, labels) are part of the
  # persisted user-data contract. Keep backward compatibility in mind before
  # changing record shapes, and prefer adding records over rewriting existing
  # files.
  class SessionStore
    VERSION = 2
    LAST_SESSION_FILENAME = "last_session.json"
    NON_ACTIVITY_RECORD_TYPES = %w[session session_info system_prompt].freeze
    RECORD_TYPE_PATTERN = /\A\{\s*"type"\s*:\s*"([^"]+)"/
    RECORD_TIMESTAMP_PATTERN = /"timestamp"\s*:\s*"([^"]+)"/

    SessionInfo = Struct.new(:id, :path, :cwd, :created_at, :modified_at, :name, :first_message, :message_count, :provider, :model, :reasoning_effort, :parent_id, :parent_path, :depth, :is_last, :ancestor_continues, keyword_init: true)

    # Live handle that attaches persistence callbacks to a conversation.
    #
    # Once attached, every append/compact/tool execution writes a JSONL record and
    # advances `leaf_id` for session tree navigation. Avoid mutating the attached
    # conversation directly without these callbacks unless deliberately importing
    # or reconstructing history.
    class Session
      # @return [String] stable persisted session id from the JSONL header
      attr_reader :id
      # @return [String] absolute JSONL session file path
      attr_reader :path
      # @return [String] workspace directory recorded when the session was created
      attr_reader :cwd
      # @return [Time] creation timestamp used for sorting and filenames
      attr_reader :created_at
      # @return [Time] timestamp of the latest persisted conversation activity
      attr_reader :modified_at
      # @return [String, nil] source session id when this session was cloned or forked
      attr_reader :parent_id
      # @return [String, nil] source session path when this session was cloned or forked
      attr_reader :parent_path
      # @return [String, nil] user-visible session name persisted as metadata records
      attr_accessor :name
      # @return [String, nil] active tree leaf id used to restore the selected branch
      attr_accessor :leaf_id

      # Creates an object for JSONL session persistence.
      def initialize(store:, id:, path:, cwd:, created_at:, name: nil, parent_id: nil, parent_path: nil, leaf_id: nil, modified_at: nil, system_prompt_hash: nil)
        @store = store
        @id = id
        @path = path
        @cwd = cwd
        @created_at = created_at
        @modified_at = modified_at || created_at
        @name = name
        @parent_id = parent_id
        @parent_path = parent_path
        @leaf_id = leaf_id
        @system_prompt_hash = system_prompt_hash
      end

      # Installs persistence callbacks on `conversation`.
      #
      # The callbacks are intentionally simple lambdas so `Conversation` remains
      # storage-agnostic while `SessionStore` remains the only owner of JSONL
      # record shape.
      def attach(conversation)
        conversation.on_append = lambda { |message| append_message(message) }
        conversation.on_compact = lambda { |message| compact(message) }
        conversation.on_tool_execution = lambda { |tool_call, content| append_tool_execution(tool_call, content) }
        conversation.on_runtime_update = lambda { |provider:, model:, reasoning_effort:| update_runtime(provider: provider, model: model, reasoning_effort: reasoning_effort) }
        conversation.on_system_message_change = lambda { |system_message| append_system_prompt_snapshot(system_message, reason: "changed") }
        append_system_prompt_snapshot(conversation.system_message, reason: "attach")
        self
      end

      # Persists a message as a tree entry and advances the session leaf.
      def append_message(message)
        record = @store.build_tree_record(@path, "message", @leaf_id, message: message)
        @leaf_id = record[:id]
        @store.append_record(@path, record)
        mark_modified(record)
      end

      # Persists a compaction summary entry and makes it the active leaf.
      def compact(message)
        record = @store.build_tree_record(@path, "compaction", @leaf_id, message: message)
        @leaf_id = record[:id]
        @store.append_record(@path, record)
        mark_modified(record)
      end

      # Persists normalized tool execution metadata alongside transcript messages.
      def append_tool_execution(tool_call, content)
        record = RPC::ToolEventNormalizer.new(tool_call, content: content).execution_record
        @store.append_record(@path, record)
        mark_modified(record)
      end

      # Persists the current system prompt as audit metadata when it changes.
      def append_system_prompt_snapshot(system_message, reason: "changed")
        @system_prompt_hash = @store.append_system_prompt_snapshot(
          @path,
          system_message,
          reason: reason,
          latest_hash: @system_prompt_hash
        )
      end

      # Persists the session memory snapshot used when the session is restored.
      def update_memory_state(session_memories:, last_retrieval: nil)
        record = {
          type: "memory_state",
          timestamp: Time.now.utc.iso8601(3),
          sessionMemories: Array(session_memories),
          lastRetrieval: last_retrieval
        }
        @store.append_record(@path, record)
        mark_modified(record)
      end

      # Persists a user-visible session name without rewriting earlier records.
      def rename(name)
        @name = name.to_s.strip.empty? ? nil : name.to_s.strip
        @store.append_record(@path, {
          type: "session_info",
          timestamp: Time.now.utc.iso8601(3),
          name: @name
        })
      end

      # Moves the active leaf to an existing entry so future messages fork there.
      def branch(entry_id)
        @leaf_id = entry_id.to_s.empty? ? nil : entry_id.to_s
        record = @store.append_leaf_change(@path, @leaf_id)
        mark_modified(record)
      end

      # Clears the active leaf so the next append starts a fresh root branch.
      def reset_leaf
        branch(nil)
      end

      # Persists a display label override for one tree entry.
      def append_label_change(entry_id, label)
        record = @store.append_label_change(@path, entry_id, label)
        mark_modified(record)
      end

      # Adds a branch-summary node under `parent_id` and selects it as the leaf.
      def append_branch_summary(parent_id, from_id:, summary:, details: {})
        record = @store.build_tree_record(@path, "branch_summary", parent_id, fromId: from_id, summary: summary, details: details || {})
        @leaf_id = record[:id]
        @store.append_record(@path, record)
        mark_modified(record)
        record[:id]
      end

      # Persists model/runtime metadata so restored sessions keep their context.
      def update_runtime(provider: nil, model:, reasoning_effort:)
        @store.append_record(@path, {
          type: "session_info",
          timestamp: Time.now.utc.iso8601(3),
          name: @name,
          provider: provider.to_s,
          model: model.to_s,
          reasoningEffort: reasoning_effort.to_s
        }.delete_if { |_key, value| value.to_s.empty? })
      end

      # Removes this session file when it is still empty and unnamed.
      def delete_if_unused
        @store.delete_unused_session(self)
      end

      private

      def mark_modified(record)
        timestamp = record[:timestamp] || record["timestamp"]
        @modified_at = Time.iso8601(timestamp.to_s) || Time.now.utc
      rescue ArgumentError
        @modified_at = Time.now.utc
      end
    end

    # Creates an object for JSONL session persistence.
    def initialize(config_dir: ConfigFiles.config_dir, cwd: Dir.pwd)
      @config_dir = config_dir
      @cwd = File.expand_path(cwd)
    end

    # @return [String] workspace directory this store lists and creates sessions for
    attr_reader :cwd

    # @return [String] configuration directory containing session and tab files
    attr_reader :config_dir

    # Creates a new empty session file for the store's workspace directory.
    #
    # Parent fields record clone/fork ancestry; they do not imply live coupling
    # between files after creation.
    def create(provider: nil, model: nil, reasoning_effort: nil, parent_id: nil, parent_path: nil)
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
        provider: provider.to_s,
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

      Session.new(store: self, id: id, path: path, cwd: @cwd, created_at: created_at, parent_id: parent_id, parent_path: parent_path, leaf_id: nil, modified_at: created_at)
    end

    def create_from_conversation(conversation, parent_session: nil)
      session = create(provider: conversation.provider, model: conversation.model, reasoning_effort: conversation.reasoning_effort, parent_id: parent_session&.id, parent_path: parent_session&.path)
      session.rename(parent_session.name) unless parent_session&.name.to_s.strip.empty?
      persisted_messages(conversation).each { |message| session.append_message(message) }
      session.attach(conversation)
      session
    end

    def create_independent_from_conversation(conversation, parent_session: nil)
      create_independent_from_messages(
        persisted_messages(conversation),
        read_paths: Array(conversation.read_paths),
        provider: conversation.provider,
        model: conversation.model,
        reasoning_effort: conversation.reasoning_effort,
        parent_session: parent_session
      )
    end

    # Creates a new session containing an independent copy of selected messages.
    #
    # Used by clone/fork flows where the new conversation must preserve selected
    # history but then diverge without mutating the source session file.
    #
    # @param messages [Array<Hash>] messages to persist into the new session
    # @param read_paths [Array<String>] restored read-before-write paths
    # @param parent_session [Session, nil] optional source session metadata
    # @return [Array(Session, Conversation)] new session handle and attached conversation
    def create_independent_from_messages(messages, read_paths: [], provider: nil, model: nil, reasoning_effort: nil, parent_session: nil)
      session = create(provider: provider, model: model, reasoning_effort: reasoning_effort, parent_id: parent_session&.id, parent_path: parent_session&.path)
      session.rename(parent_session.name) unless parent_session&.name.to_s.strip.empty?
      persisted = persistence_copy(messages)
      persisted.each { |message| session.append_message(message) }
      conversation = Conversation.new(messages: persistence_copy(persisted), read_paths: read_paths, workspace_root: @cwd, provider: provider, model: model, reasoning_effort: reasoning_effort)
      session.attach(conversation)
      [session, conversation]
    end

    # Resolves a user-provided path and returns the stored workspace location.
    #
    # @return [Hash] `:path` and `:cwd` for loading the session safely
    def session_location(path)
      resolved_path = resolve_session_path(path)
      records = records_from_file(resolved_path)
      header = session_header(records, resolved_path)
      { path: resolved_path, cwd: header["cwd"].to_s.empty? ? @cwd : header["cwd"].to_s }
    end

    # Loads a session file and reconstructs its current conversation leaf.
    #
    # `workspace` is used both for the active root and to restore read-before-write
    # paths from successful read tool results. If a session moved workspaces, load
    # it through `session_location` first so the original cwd is respected.
    def load(path, workspace: Workspace.new, provider: nil, model: nil, reasoning_effort: nil, project_skill_paths: nil)
      resolved_path = resolve_session_path(path)
      records = records_from_file(resolved_path)
      header = session_header(records, resolved_path)

      leaf_id = current_leaf_id(records)
      messages = restored_messages(records)
      name = session_name(records)
      read_paths = restored_read_paths(messages, workspace)
      memory_state = restored_memory_state(records)

      runtime = session_runtime(records, header)
      conversation = Conversation.new(
        messages: messages,
        read_paths: read_paths,
        workspace_root: workspace.root,
        provider: runtime["provider"] || provider,
        model: runtime["model"] || model,
        reasoning_effort: runtime["reasoningEffort"] || reasoning_effort,
        session_memories: memory_state["sessionMemories"],
        last_memory_retrieval: memory_state["lastRetrieval"],
        project_skill_paths: project_skill_paths
      )
      restore_tool_output_artifacts(records, conversation)
      conversation.mark_last_entry_compaction! if latest_record_type(records) == "compaction"
      created_at = parse_time(header["timestamp"]) || File.mtime(resolved_path)
      session = Session.new(
        store: self,
        id: header["id"],
        path: resolved_path,
        cwd: header["cwd"].to_s,
        created_at: created_at,
        name: name,
        parent_id: header["parentId"],
        parent_path: header["parentPath"],
        leaf_id: leaf_id,
        modified_at: session_modified_at(records, fallback: created_at),
        system_prompt_hash: latest_system_prompt_hash(records)
      )
      session.attach(conversation)
      [session, conversation]
    end

    # Lists recent non-empty sessions for this workspace.
    #
    # @param limit [Integer, nil] maximum number of sessions, or nil for all
    # @param keep_empty_path [String, Array<String>, nil] live empty session path(s) to preserve while omitting them from results
    # @return [Array<SessionInfo>] newest sessions first
    def recent(limit: 20, keep_empty_path: nil)
      recent_sessions(limit: limit, keep_empty_path: keep_empty_path)
    end

    # Lists all persisted sessions under this config directory for an explicit
    # user-selected operation such as skill capture. Unlike #recent, this is not
    # scoped to the store's current workspace.
    def capture_candidates
      pattern = File.join(@config_dir, "sessions", "**", "*.jsonl")
      Dir.glob(pattern).filter_map { |path| session_info(path) }.sort_by(&:modified_at).reverse
    rescue StandardError
      []
    end

    # Persists the last active session pointer for workspace auto-resume.
    def remember_last_session(session)
      return unless session&.path

      FileUtils.mkdir_p(session_dir, mode: 0o700)
      PrivateFile.write_json(last_session_path, { "path" => File.expand_path(session.path), "timestamp" => Time.now.utc.iso8601(3) })
    end

    def last_session_path
      File.join(session_dir, LAST_SESSION_FILENAME)
    end

    # @return [String, nil] remembered session path when the file still exists
    def remembered_last_session_path
      return nil unless File.file?(last_session_path)

      path = JSON.parse(File.read(last_session_path))["path"].to_s
      return nil if path.empty? || !File.file?(path)

      path
    rescue JSON::ParserError
      nil
    end

    # Lists recent sessions decorated with parent/branch display metadata.
    #
    # @return [Array<SessionInfo>] recent sessions with tree depth fields
    def recent_tree(limit: 20, keep_empty_path: nil)
      decorate_tree(recent_sessions(limit: limit, keep_empty_path: keep_empty_path))
    end

    # Deletes an empty unnamed session file.
    #
    # @return [Boolean] true when a file was removed
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


    # Builds a persisted tree record and assigns a stable entry id to messages.
    #
    # @return [Hash] JSONL-ready tree record
    def build_tree_record(path, type, parent_id, fields = {})
      message = fields[:message]
      id = message_entry_id(message) || next_entry_id(path)
      assign_message_entry_id(message, id) if message.is_a?(Hash)
      {
        type: type,
        id: id,
        parentId: parent_id,
        timestamp: Time.now.utc.iso8601(3)
      }.merge(fields).delete_if { |_key, value| value.nil? }
    end

    def append_leaf_change(path, leaf_id)
      record = {
        type: "leaf",
        timestamp: Time.now.utc.iso8601(3),
        targetId: leaf_id
      }
      append_record(path, record)
      record
    end

    def append_label_change(path, entry_id, label)
      record = {
        type: "label",
        id: next_entry_id(path),
        timestamp: Time.now.utc.iso8601(3),
        targetId: entry_id.to_s,
        label: label.to_s.strip.empty? ? nil : label.to_s.strip
      }
      append_record(path, record)
      record
    end

    # @return [Array<Hash>] nested session tree roots for the given session file
    def session_tree(path)
      records = records_from_file(resolve_session_path(path))
      build_session_tree(records)
    end

    # @return [Array<Hash>] flat tree records with resolved labels attached
    def session_entries(path)
      records = records_from_file(resolve_session_path(path))
      labels = labels_by_target(records)
      timestamps = label_timestamps_by_target(records)
      records.select { |record| tree_entry_record?(record) }.map do |record|
        id = record["id"].to_s
        record.dup.tap do |copy|
          copy["resolvedLabel"] = labels[id] if labels.key?(id)
          copy["labelTimestamp"] = timestamps[id] if timestamps.key?(id)
        end
      end
    end

    # Finds one persisted tree entry by id.
    #
    # @return [Hash, nil]
    def session_entry(path, entry_id)
      session_entries(path).find { |record| record["id"].to_s == entry_id.to_s }
    end

    # @return [String, nil] current active tree leaf id
    def current_leaf(path)
      current_leaf_id(records_from_file(resolve_session_path(path)))
    end

    # Returns the complete persisted active branch for an explicit export-like
    # consumer. Unlike #load, this does not attach a conversation or mutate the
    # session file.
    #
    # @return [Hash] session metadata, saved system-prompt snapshots, and active branch records
    def capture_branch(path)
      resolved_path = resolve_session_path(path)
      records = records_from_file(resolved_path)
      {
        path: resolved_path,
        header: session_header(records, resolved_path),
        system_prompts: records.select { |record| record["type"] == "system_prompt" },
        entries: branch_records(records)
      }
    end

    def append_record(path, record)
      File.open(path, "a", 0o600) do |file|
        file.write(JSON.generate(record))
        file.write("\n")
      end
    end

    def append_system_prompt_snapshot(path, system_message, reason: "changed", latest_hash: nil)
      content = MessageAccess.content(system_message).to_s
      return latest_hash if content.empty?

      hash = system_prompt_hash(content)
      latest_hash ||= latest_system_prompt_hash(records_from_file(path))
      return latest_hash if latest_hash == hash

      append_record(path, {
        type: "system_prompt",
        timestamp: Time.now.utc.iso8601(3),
        reason: reason.to_s,
        hash: hash,
        content: content
      })
      hash
    end

    def self.safe_cwd(cwd)
      "--#{File.expand_path(cwd).sub(%r{\A[/\\]}, "").gsub(%r{[/\\:]}, "-")}--"
    end

    private

    def session_modified_at(records, fallback:)
      records.reverse_each do |record|
        next if NON_ACTIVITY_RECORD_TYPES.include?(record["type"].to_s)

        timestamp = parse_time(record["timestamp"])
        return timestamp if timestamp
      end
      fallback
    end

    def latest_system_prompt_hash(records)
      records.reverse_each do |record|
        next unless record["type"] == "system_prompt"

        return record["hash"].to_s unless record["hash"].to_s.empty?
      end
      nil
    end

    def system_prompt_hash(content)
      "sha256:#{Digest::SHA256.hexdigest(content.to_s)}"
    end

    def resolve_session_path(path)
      expanded = path.to_s.start_with?("~/") ? File.join(Dir.home, path.to_s[2..]) : path.to_s
      resolved = File.expand_path(expanded, @cwd)
      raise "Session file not found: #{resolved}" unless File.file?(resolved)

      resolved
    end

    def records_from_file(path)
      records = File.readlines(path, chomp: true).filter_map do |line|
        JSON.parse(line)
      rescue JSON::ParserError
        nil
      end
      normalize_tree_records(records)
    end

    def normalize_tree_records(records)
      records.each do |record|
        next unless tree_entry_record?(record) && !record["id"].to_s.empty?

        assign_message_entry_id(record["message"], record["id"]) if record["message"].is_a?(Hash) && message_entry_id(record["message"]).to_s.empty?
      end
      records
    end

    def session_header(records, path)
      header = records.find { |record| record["type"] == "session" }
      return header if header && header["id"].to_s != ""

      recovered = recovered_session_header(records, path)
      return recovered if recovered

      raise "Invalid Kward session file: #{path}"
    end

    def recovered_session_header(records, path)
      return nil unless records.any? { |record| ["message", "session_info", "system_prompt", "memory_state"].include?(record["type"]) }

      basename = File.basename(path)
      match = basename.match(/\A(?<timestamp>\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}\.\d{3}Z)_(?<id>[0-9a-fA-F-]{36})\.jsonl\z/)
      return nil unless match

      timestamp = match[:timestamp].tr("-", ":").sub(/\A(\d{4}):(\d{2}):(\d{2})T/, "\\1-\\2-\\3T")
      {
        "type" => "session",
        "version" => VERSION,
        "id" => match[:id],
        "timestamp" => timestamp,
        "cwd" => @cwd
      }
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

    def restore_tool_output_artifacts(records, conversation)
      tool_names = tool_message_names_by_id(records)
      records.each do |record|
        next unless record["type"] == "tool_execution_end"

        content = record.dig("result", "content")
        next if content.nil?

        tool_name = tool_names[record["toolCallId"].to_s] || raw_tool_name(record["toolName"])
        next if tool_name.to_s.empty?

        conversation.restore_tool_output_artifact(
          tool_name: tool_name,
          content: content,
          created_at: parse_time(record["timestamp"])
        )
      end
    end

    def tool_message_names_by_id(records)
      records.each_with_object({}) do |record, names|
        next unless record["type"] == "message"

        message = record["message"]
        next unless message.is_a?(Hash) && message_role(message) == "tool"

        tool_call_id = message_tool_call_id(message).to_s
        names[tool_call_id] = message_name(message) unless tool_call_id.empty? || message_name(message).to_s.empty?
      end
    end

    def raw_tool_name(name)
      {
        "bash" => "run_shell_command",
        "edit" => "edit_file",
        "read" => "read_file",
        "write" => "write_file"
      }.fetch(name.to_s, name.to_s)
    end

    def session_runtime(records, header)
      result = {
        "provider" => header["provider"],
        "model" => header["model"],
        "reasoningEffort" => header["reasoningEffort"]
      }
      records.each do |record|
        next unless record["type"] == "session_info"

        result["provider"] = record["provider"] if record.key?("provider")
        result["model"] = record["model"] if record.key?("model")
        result["reasoningEffort"] = record["reasoningEffort"] if record.key?("reasoningEffort")
      end
      result.delete_if { |_key, value| value.to_s.empty? }
    end

    def restored_messages(records)
      branch_records(records).each_with_object([]) do |record, messages|
        message = record["message"]
        case record["type"]
        when "message"
          messages << message if message.is_a?(Hash)
        when "compaction"
          messages.replace(rebuilt_compacted_messages(message, messages)) if message.is_a?(Hash)
        when "branch_summary"
          messages << { "role" => "branchSummary", "content" => record["summary"].to_s, "id" => record["id"] }
        end
      end
    end


    def build_session_tree(records)
      entries = records.select { |record| tree_entry_record?(record) }
      labels = labels_by_target(records)
      label_timestamps = label_timestamps_by_target(records)
      nodes = entries.each_with_object({}) do |entry, map|
        id = entry["id"].to_s
        next if id.empty?

        node = { "entry" => decorate_tree_entry(entry), "children" => [] }
        node["label"] = labels[id] if labels.key?(id)
        node["labelTimestamp"] = label_timestamps[id] if label_timestamps.key?(id)
        map[id] = node
      end
      roots = []
      entries.each do |entry|
        id = entry["id"].to_s
        node = nodes[id]
        next unless node

        parent = nodes[entry["parentId"].to_s]
        if parent && !parent.equal?(node)
          parent["children"] << node unless parent["children"].include?(node)
        else
          roots << node unless roots.include?(node)
        end
      end
      roots
    end

    def decorate_tree_entry(entry)
      entry.dup
    end

    def branch_records(records)
      entries = records.select { |record| tree_entry_record?(record) && !record["id"].to_s.empty? }
      by_id = entries.to_h { |record| [record["id"].to_s, record] }
      leaf_id = current_leaf_id(records)
      return [] if leaf_id.nil?

      branch = []
      seen = {}
      current = by_id[leaf_id.to_s]
      while current && !seen[current["id"].to_s]
        seen[current["id"].to_s] = true
        branch << current
        parent_id = current["parentId"]
        current = parent_id ? by_id[parent_id.to_s] : nil
      end
      branch.reverse
    end

    def current_leaf_id(records)
      latest = records.reverse.find { |record| record["type"] == "leaf" || (tree_entry_record?(record) && !record["id"].to_s.empty?) }
      return nil unless latest
      return latest["targetId"] if latest["type"] == "leaf"

      latest["id"]
    end

    def tree_entry_record?(record)
      ["message", "compaction", "branch_summary"].include?(record["type"])
    end

    def labels_by_target(records)
      records.each_with_object({}) do |record, labels|
        next unless record["type"] == "label"

        target = record["targetId"].to_s
        next if target.empty?

        label = record["label"].to_s.strip
        label.empty? ? labels.delete(target) : labels[target] = label
      end
    end

    def label_timestamps_by_target(records)
      records.each_with_object({}) do |record, timestamps|
        next unless record["type"] == "label"

        target = record["targetId"].to_s
        next if target.empty?

        if record["label"].to_s.strip.empty?
          timestamps.delete(target)
        else
          timestamps[target] = record["timestamp"]
        end
      end
    end

    def next_entry_id(_path)
      SecureRandom.hex(16)
    end

    def message_entry_id(message)
      return nil unless message.respond_to?(:key?)

      message["id"] || message[:id]
    end

    def assign_message_entry_id(message, id)
      message["id"] = id
      message.delete(:id) if message.key?(:id)
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

    def recent_sessions(limit: nil, keep_empty_path: nil)
      keep_empty_paths = Array(keep_empty_path).filter_map do |path|
        File.expand_path(path) unless path.to_s.empty?
      end
      paths = Dir.glob(File.join(session_dir, "*.jsonl")).sort_by { |path| session_file_activity_time(path) }.reverse
      sessions = []

      paths.each do |path|
        if limit.nil? || sessions.length < limit
          info = session_info(path)
          next unless info
          next if delete_empty_unnamed_session_info(info, keep_empty_paths: keep_empty_paths)

          sessions << info
        else
          delete_empty_unnamed_session_path(path, keep_empty_paths: keep_empty_paths)
        end
      end
      sessions
    end

    def delete_empty_unnamed_session_info(info, keep_empty_paths: [])
      return false unless info.name.to_s.strip.empty? && info.message_count.to_i.zero?
      return true if keep_empty_paths.include?(File.expand_path(info.path))

      File.delete(info.path)
      true
    rescue StandardError
      false
    end

    def session_file_activity_time(path)
      latest_timestamp = nil
      File.foreach(path) do |line|
        type = line[RECORD_TYPE_PATTERN, 1]
        next if NON_ACTIVITY_RECORD_TYPES.include?(type.to_s)

        timestamp = line[RECORD_TIMESTAMP_PATTERN, 1]
        latest_timestamp = timestamp if timestamp
      end
      parse_time(latest_timestamp) || File.mtime(path)
    rescue StandardError
      Time.at(0)
    end

    def delete_empty_unnamed_session_path(path, keep_empty_paths: [])
      return false unless empty_unnamed_session_path?(path)
      return true if keep_empty_paths.include?(File.expand_path(path))

      File.delete(path)
      true
    rescue StandardError
      false
    end

    def empty_unnamed_session_path?(path)
      header = false
      name = nil
      File.foreach(path) do |line|
        record = JSON.parse(line)
        header = true if record["type"] == "session" && !record["id"].to_s.empty?
        name = record["name"] if record["type"] == "session_info" && record.key?("name")
        next unless record["type"] == "message"

        return false if ["user", "assistant", "tool"].include?(message_role(record["message"] || {}))
      end
      header && name.to_s.strip.empty?
    rescue JSON::ParserError
      false
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
      header = session_header(records, path)

      messages = restored_messages(records)
      name = session_name(records)
      runtime = session_runtime(records, header)
      first_message = messages.find { |message| ["user", "compactionSummary"].include?(message_role(message)) }
      stats = File.stat(path)
      created_at = parse_time(header["timestamp"]) || stats.mtime

      SessionInfo.new(
        id: header["id"],
        path: path,
        cwd: header["cwd"].to_s,
        created_at: created_at,
        modified_at: session_modified_at(records, fallback: stats.mtime),
        name: name,
        first_message: first_message ? message_text(first_message) : "",
        message_count: messages.count { |message| ["user", "assistant", "tool", "toolResult", "compactionSummary"].include?(message_role(message)) },
        provider: runtime["provider"],
        model: runtime["model"],
        reasoning_effort: runtime["reasoningEffort"],
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
      conversation.messages.reject { |message| message_role(message) == "system" }.map { |message| persistence_copy(message) }
    end

    def persistence_copy(value)
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
          next unless path && !content.start_with?("Error:")

          begin
            read_paths << workspace.resolved_path(path)
          rescue Errno::ENOENT, SecurityError
            next
          end
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

    def message_text(message)
      MessageText.preview(message)
    end

    def parse_time(value)
      Time.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end
  end
end

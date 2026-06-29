require_relative "../agent"
require_relative "../config_files"
require_relative "../model/client"
require_relative "../tools/registry"
require_relative "../workspace"
require_relative "git_guard"
require_relative "tool_policy"

module Kward
  module Workers
    # Executes session-backed worker queue jobs one at a time.
    class QueueRunner
      CONTINUE_PROMPT = <<~PROMPT.freeze
        Continue this session as an implementation worker.
        Make the smallest correct change, preserve existing style, and run focused verification when practical.
        Stop when the work is ready for human review.
      PROMPT

      def initialize(queue_store:, session_store:, client_factory: -> { Client.new }, prompt: nil, workspace_root: Dir.pwd, provider: nil, model: nil, reasoning_effort: nil, git_guard: nil, write_lock: nil)
        @queue_store = queue_store
        @session_store = session_store
        @client_factory = client_factory
        @prompt = prompt
        @workspace_root = ConfigFiles.canonical_workspace_root(workspace_root)
        @provider = provider
        @model = model
        @reasoning_effort = reasoning_effort
        @git_guard = git_guard || GitGuard.new(root: @workspace_root)
        @write_lock = write_lock
      end

      def run_next
        record = @queue_store.next_queued
        return nil unless record

        run_job(record)
      end

      private

      def run_job(record)
        id = record.fetch("id")
        @queue_store.update_status(id, "running", error: "")
        session, conversation = load_job_session(record)
        agent = Agent.new(client: @client_factory.call, tool_registry: tool_registry(record, id), conversation: conversation)
        report = agent.ask(CONTINUE_PROMPT)
        commit = commit_if_needed(record)
        session.append_message({ role: "assistant", content: completion_report(report, commit) }) if commit
        @queue_store.update_status(id, "ready_for_review", commit_sha: commit, error: "")
      rescue StandardError => e
        @queue_store.update_status(id, "failed", error: e.message)
      end

      def load_job_session(record)
        @session_store.load(
          record.fetch("session_path"),
          workspace: Workspace.new(root: record["workspace_root"] || @workspace_root),
          provider: @provider,
          model: @model,
          reasoning_effort: @reasoning_effort
        )
      end

      def tool_registry(record, writer_id)
        ToolRegistry.new(
          workspace: Workspace.new(root: record["workspace_root"] || @workspace_root),
          prompt: @prompt,
          allowed_tool_names: ToolPolicy.allowed_tool_names("implementation"),
          write_lock: @write_lock,
          writer_id: writer_id
        )
      end

      def commit_if_needed(record)
        return nil unless @git_guard.repository?
        return nil if @git_guard.clean?

        result = @git_guard.commit_all(commit_message(record))
        raise "Worker changed files but commit failed: #{result.output}" unless result.success?

        result.commit
      end

      def commit_message(record)
        "Kward worker #{record.fetch('id')}: #{record.fetch('title')}"
      end

      def completion_report(report, commit)
        [report, "", "Committed workspace changes: #{commit}"].join("\n")
      end
    end
  end
end

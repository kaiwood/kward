require "timeout"
require_relative "../agent"
require_relative "../cancellation"
require_relative "../conversation"
require_relative "../hooks"
require_relative "../model/client"
require_relative "../session_store"
require_relative "../tools/registry"
require_relative "../workspace"
require_relative "git_guard"
require_relative "tool_policy"
require_relative "worker"

module Kward
  module Workers
    # Coordinates background worker execution and role-specific tool policy.
    class Manager
      DEFAULT_TIMEOUT_SECONDS = 180

      def initialize(client_factory: -> { Client.new }, prompt: nil, workspace_root: Dir.pwd, timeout_seconds: DEFAULT_TIMEOUT_SECONDS, on_status_change: nil, session_store: nil, provider: nil, model: nil, reasoning_effort: nil, write_lock: nil, worker_store: nil, git_guard: nil, write_lane_available: -> { true }, hook_manager: nil, hook_context: nil)
        @client_factory = client_factory
        @prompt = prompt
        @workspace_root = ConfigFiles.canonical_workspace_root(workspace_root)
        @timeout_seconds = timeout_seconds
        @on_status_change = on_status_change
        @session_store = session_store
        @provider = provider
        @model = model
        @reasoning_effort = reasoning_effort
        @write_lock = write_lock
        @worker_store = worker_store
        @git_guard = git_guard || GitGuard.new(root: @workspace_root)
        @write_lane_available = write_lane_available
        @hook_manager = hook_manager
        @hook_context = hook_context
        @workers = {}
        @mutex = Mutex.new
      end

      def start(role:, prompt:, title: nil, id: nil)
        worker = build_worker(role: role, prompt: prompt, title: title, id: id)
        run_hook("worker_job_create", worker)
        enqueue(worker)
      end

      def continue(id, role:, prompt:, title: nil)
        archived = nil
        worker = build_worker(role: role, prompt: prompt, title: title, id: id)
        @mutex.synchronize do
          archived = @workers.delete(id.to_s)
          @workers[worker.id] = worker
        end
        archived&.update_status("archived")
        @worker_store&.archive(id) if archived || @worker_store&.find(id)
        enqueue(worker, store: false)
      end

      def list
        @mutex.synchronize { @workers.values.reject { |worker| worker.status == "archived" }.sort_by(&:created_at) }
      end

      def find(id)
        @mutex.synchronize { @workers[id.to_s] }
      end

      def cancel(id)
        worker = find(id) || raise(ArgumentError, "Unknown worker: #{id}")
        worker.cancellation.cancel!
        worker.thread.raise(Cancellation::CancelledError, "cancelled") if worker.thread&.alive?
        update_status(worker, "cancelled")
      end

      def archive(id)
        worker = find(id) || raise(ArgumentError, "Unknown worker: #{id}")
        worker.cancellation.cancel! if %w[queued running].include?(worker.status)
        worker.thread.raise(Cancellation::CancelledError, "cancelled") if worker.thread&.alive?
        update_status(worker, "archived")
      end

      private

      def build_worker(role:, prompt:, title: nil, id: nil)
        Worker.new(
          id: id || SecureRandom.hex(4),
          title: title || title_for(prompt),
          role: role,
          prompt: prompt,
          workspace_root: @workspace_root,
          status: "queued"
        )
      end

      def enqueue(worker, store: true)
        @mutex.synchronize { @workers[worker.id] = worker }
        @worker_store&.upsert(worker) if store
        worker.thread = Thread.new { run_worker(worker) }
        worker.thread.report_on_exception = false
        worker
      end

      def run_worker(worker)
        conversation = Conversation.new(
          system_message: { role: "system", content: system_message(worker) },
          workspace_root: worker.workspace_root,
          provider: @provider,
          model: @model,
          reasoning_effort: @reasoning_effort
        )
        worker.conversation = conversation
        attach_session(worker, conversation)
        writer_id = wait_for_worker_writer(worker)
        run_hook("worker_job_start_before", worker)
        update_status(worker, "running")
        run_hook("worker_job_start_after", worker)
        registry = ToolRegistry.new(
          workspace: Workspace.new(root: worker.workspace_root),
          prompt: @prompt,
          allowed_tool_names: ToolPolicy.allowed_tool_names(worker.role),
          write_lock: @write_lock,
          writer_id: writer_id,
          hook_manager: @hook_manager,
          hook_context: @hook_context
        )
        agent = Agent.new(client: @client_factory.call, tool_registry: registry, conversation: conversation, hook_manager: @hook_manager, hook_context: @hook_context)
        report = Timeout.timeout(@timeout_seconds, WorkerTimeoutError) do
          agent.ask(worker_prompt(worker), cancellation: worker.cancellation) do |event|
            worker.record_event(event)
          end
        end
        report = finalize_write_worker(worker, report)
        update_status(worker, "ready", report: report, error: "")
        run_hook("worker_job_ready_for_review", worker)
      rescue WorkerTimeoutError
        update_status(worker, "failed", error: "Worker timed out after #{@timeout_seconds} seconds")
        run_hook("worker_job_failed", worker, error: "Worker timed out after #{@timeout_seconds} seconds")
      rescue Cancellation::CancelledError
        update_status(worker, "cancelled")
      rescue StandardError => e
        update_status(worker, "failed", error: e.message)
        run_hook("worker_job_failed", worker, error: e.message)
      ensure
        release_worker_writer(worker)
      end

      def run_hook(name, worker, payload = {})
        return unless @hook_manager

        @hook_manager.run(Hooks::Event.new(
          name: name,
          workspace: { root: worker.workspace_root },
          payload: worker_payload(worker).merge(payload)
        ), context: @hook_context)
      rescue StandardError
        nil
      end

      def worker_payload(worker)
        {
          worker_id: worker.id,
          role: worker.role,
          title: worker.title,
          status: worker.status,
          session_path: worker.session&.path
        }.compact
      end

      def update_status(worker, status, **values)
        return worker if worker.status == "archived" && status.to_s != "archived"

        worker.update_status(status, **values)
        @worker_store&.upsert(worker)
        @on_status_change&.call(worker)
        worker
      end

      def wait_for_worker_writer(worker)
        return nil unless ToolPolicy.write_capable?(worker.role)

        loop do
          worker.cancellation.raise_if_cancelled!
          wait_for_write_lane_available(worker)
          wait_for_clean_workspace(worker)
          return worker.id unless @write_lock

          release_foreground_writer_if_clean
          return worker.id if @write_lock.acquire(worker.id)

          sleep 0.1
        end
      end

      def wait_for_write_lane_available(worker)
        until @write_lane_available.call
          worker.cancellation.raise_if_cancelled!
          sleep 0.1
        end
      end

      def wait_for_clean_workspace(worker)
        return unless @git_guard.repository?

        until @git_guard.clean?
          worker.cancellation.raise_if_cancelled!
          sleep 0.5
        end
      end

      def release_foreground_writer_if_clean
        return unless @write_lock&.owned_by?("implementation")
        return unless @git_guard.repository?
        return unless @git_guard.clean?

        @write_lock.release("implementation")
      end

      def finalize_write_worker(worker, report)
        return report unless ToolPolicy.write_capable?(worker.role)
        return report unless @git_guard.repository?
        return report if @git_guard.clean?

        commit = @git_guard.commit_all(commit_message(worker))
        unless commit.success?
          raise "Worker changed files but commit failed: #{commit.output}"
        end

        [report, "", "Committed workspace changes: #{commit.commit}"].join("\n")
      end

      def commit_message(worker)
        "Kward worker #{worker.id}: #{worker.title}"
      end

      def release_worker_writer(worker)
        return unless ToolPolicy.write_capable?(worker.role)

        @write_lock&.release(worker.id)
      end

      def attach_session(worker, conversation)
        return unless @session_store

        session = @session_store.create(provider: @provider, model: @model, reasoning_effort: @reasoning_effort)
        session.rename("#{worker.role}: #{worker.title}")
        session.attach(conversation)
        worker.session = session
        @worker_store&.upsert(worker)
        @on_status_change&.call(worker)
      rescue StandardError
        nil
      end

      def worker_prompt(worker)
        return request_prompt(worker.prompt) if worker.role == "request"

        worker.prompt
      end

      def system_message(worker)
        return request_system_message if worker.role == "request"

        "You are a Kward worker. Complete the user's task carefully."
      end

      def request_system_message
        <<~SYSTEM
          You are a Kward request worker running the read-only exploration phase.
          Inspect the workspace, map relevant terrain, and produce a practical review for the user.
          Do not edit files, write files, delete files, alter configuration, or claim implementation work was done.
        SYSTEM
      end

      def request_prompt(prompt)
        <<~PROMPT
          #{prompt}

          ---

          You are handling this as a structured Kward background request.
          First perform a read-only exploration phase. Inspect relevant files and documentation, reason about the request, and prepare a reviewable result for the user.
          Do not modify files, write files, delete files, alter configuration, run destructive commands, or claim implementation work was done.

          Return a concise request review with these sections:
          # Request Review: <title>

          ## Request
          Restate the user's request.

          ## Summary
          The short answer.

          ## Relevant files
          Bullet list of likely files and why they matter.

          ## Findings
          What you discovered.

          ## Recommended next step
          A practical next step. If implementation appears useful, say so clearly, but do not implement it.

          ## Risks
          Important risks or unknowns.

          ## Verification
          Focused verification commands or checks.

          ## Open questions
          Decisions the user should make before proceeding.

          End by asking: Should we proceed?
        PROMPT
      end

      def title_for(prompt)
        text = prompt.to_s.strip.gsub(/\s+/, " ")
        text.empty? ? "Untitled worker" : text[0, 80]
      end

      class WorkerTimeoutError < StandardError; end
    end
  end
end

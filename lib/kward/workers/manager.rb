require "timeout"
require_relative "../agent"
require_relative "../cancellation"
require_relative "../conversation"
require_relative "../model/client"
require_relative "../session_store"
require_relative "../tools/registry"
require_relative "../workspace"
require_relative "tool_policy"
require_relative "worker"

module Kward
  module Workers
    # Coordinates background worker execution and role-specific tool policy.
    class Manager
      DEFAULT_TIMEOUT_SECONDS = 180

      def initialize(client_factory: -> { Client.new }, prompt: nil, workspace_root: Dir.pwd, timeout_seconds: DEFAULT_TIMEOUT_SECONDS, on_status_change: nil, session_store: nil, provider: nil, model: nil, reasoning_effort: nil)
        @client_factory = client_factory
        @prompt = prompt
        @workspace_root = ConfigFiles.canonical_workspace_root(workspace_root)
        @timeout_seconds = timeout_seconds
        @on_status_change = on_status_change
        @session_store = session_store
        @provider = provider
        @model = model
        @reasoning_effort = reasoning_effort
        @workers = {}
        @mutex = Mutex.new
      end

      def start(role:, prompt:, title: nil, id: nil)
        worker = Worker.new(
          id: id || SecureRandom.hex(4),
          title: title || title_for(prompt),
          role: role,
          prompt: prompt,
          workspace_root: @workspace_root,
          status: "queued"
        )
        @mutex.synchronize { @workers[worker.id] = worker }
        worker.thread = Thread.new { run_worker(worker) }
        worker.thread.report_on_exception = false
        worker
      end

      def list
        @mutex.synchronize { @workers.values.sort_by(&:created_at) }
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

      private

      def run_worker(worker)
        update_status(worker, "running")
        conversation = Conversation.new(
          system_message: { role: "system", content: system_message(worker) },
          workspace_root: worker.workspace_root,
          provider: @provider,
          model: @model,
          reasoning_effort: @reasoning_effort
        )
        worker.conversation = conversation
        attach_session(worker, conversation)
        registry = ToolRegistry.new(
          workspace: Workspace.new(root: worker.workspace_root),
          prompt: @prompt,
          allowed_tool_names: ToolPolicy.allowed_tool_names(worker.role)
        )
        agent = Agent.new(client: @client_factory.call, tool_registry: registry, conversation: conversation)
        report = Timeout.timeout(@timeout_seconds, WorkerTimeoutError) do
          agent.ask(worker_prompt(worker), cancellation: worker.cancellation) do |event|
            worker.record_event(event)
          end
        end
        update_status(worker, "ready", report: report, error: "")
      rescue WorkerTimeoutError
        update_status(worker, "failed", error: "Worker timed out after #{@timeout_seconds} seconds")
      rescue Cancellation::CancelledError
        update_status(worker, "cancelled")
      rescue StandardError => e
        update_status(worker, "failed", error: e.message)
      end

      def update_status(worker, status, **values)
        worker.update_status(status, **values)
        @on_status_change&.call(worker)
        worker
      end

      def attach_session(worker, conversation)
        return unless @session_store

        session = @session_store.create(provider: @provider, model: @model, reasoning_effort: @reasoning_effort)
        session.rename("#{worker.role}: #{worker.title}")
        session.attach(conversation)
        worker.session = session
        @on_status_change&.call(worker)
      rescue StandardError
        nil
      end

      def worker_prompt(worker)
        return scout_prompt(worker.prompt) if worker.role == "scout"

        worker.prompt
      end

      def system_message(worker)
        return scout_system_message if worker.role == "scout"

        "You are a Kward worker. Complete the user's task carefully."
      end

      def scout_system_message
        <<~SYSTEM
          You are a Kward scout: a read-only background researcher and planner for future coding work.
          Inspect the workspace, map relevant terrain, and produce a practical report.
          Do not edit files, write files, delete files, alter configuration, or claim implementation work was done.
        SYSTEM
      end

      def scout_prompt(prompt)
        <<~PROMPT
          Scout this future coding task in read-only mode:

          #{prompt}

          You are a scout, not an implementer. Explore the repository and any relevant documentation, but do not change files, configuration, or project state.

          Return a concise scout report with these sections:
          # Scout Report: <title>

          ## Request
          Restate the request.

          ## Summary
          The short answer.

          ## Relevant files
          Bullet list of likely files and why they matter.

          ## Findings
          What you discovered.

          ## Recommended route
          A practical implementation plan.

          ## Risks
          Important risks or unknowns.

          ## Tests to run
          Focused verification commands.

          ## Open questions
          Decisions the user should make before implementation.
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

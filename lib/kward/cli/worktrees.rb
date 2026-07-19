# Namespace for the Kward CLI agent runtime.
module Kward
  # Coordinates Git worktree bindings with session-backed tab runtimes.
  class CLI
    module Worktrees
      private

      def git_worktree_manager
        @git_worktree_manager ||= GitWorktreeManager.new
      end

      def worktree_binding_for(tab)
        driver = tab&.driver
        driver.worktree if driver&.respond_to?(:worktree)
      end

      def worktree_root_for(binding, fallback: current_workspace_root)
        return fallback unless binding

        binding.active? ? binding.path : binding.origin_root
      end

      def validate_worktree_binding!(binding)
        return unless binding

        unless File.directory?(binding.origin_root)
          raise GitWorktreeManager::Error, "Original workspace is unavailable: #{binding.origin_root}"
        end

        return unless binding.active?

        info = git_worktree_manager.inspect(repository_root: binding.repository_root, path: binding.path)
        return if info.branch == binding.branch

        raise GitWorktreeManager::Error, "Worktree branch changed: expected #{binding.branch}, found #{info.branch || "detached HEAD"}"
      end

      def rebind_session_tab(tab, root:, worktree:)
        raise GitWorktreeManager::Error, "A session tab is required." unless tab&.session
        raise GitWorktreeManager::Error, "The session store is unavailable." unless @session_store

        session, conversation = @session_store.load(
          tab.session.path,
          workspace: configured_workspace(root: root),
          provider: current_model_provider,
          model: current_model_id,
          reasoning_effort: current_reasoning_effort
        )
        agent = build_tab_agent(conversation, session)
        tab.session = track_session(session)
        tab.agent = agent
        tab.driver = SessionTabDriver.new(session: tab.session, agent: agent, worktree: worktree)
        tab.diff = SessionDiff.from_session_file(tab.session.path)
        tab.status = "idle"
        tab.thread = nil
        tab.cancellation = nil
        tab.steering = nil
        tab.error = nil
        tab.answer = nil
        tab.pending_question = nil
        tab.unread = false
        tab.error_reported = false
        tab.event_history.clear
        tab.seen_events = 0
        tab.queued_inputs.clear
        tab.shell = nil
        tab.stream_state = new_tab_stream_state(tab.driver)
        tab.markdown_chunks.clear
        assign_tab_question_prompt(tab.agent, tab)
        if tab == active_tab
          @active_session = tab.session
          @session_diff = tab.diff
          update_assistant_prompt(tab.agent.conversation)
        end
        tab
      end

      def unavailable_worktree_tab(descriptor, error, label: nil)
        driver = UnavailableTabDriver.new(
          descriptor: descriptor,
          message: "Worktree unavailable: #{error.message}"
        )
        build_tab(nil, nil, driver: driver, label: label || descriptor["label"] || "Worktree")
      end
    end
  end
end

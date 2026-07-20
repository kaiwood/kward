require "securerandom"

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

      def reconcile_worktree_binding(tab, conversation)
        binding = worktree_binding_for(tab)
        return nil unless binding
        return binding unless binding.active?

        binding.active = false unless File.realpath(conversation.workspace_root) == File.realpath(binding.path)
        binding
      rescue Errno::ENOENT, Errno::ENOTDIR
        binding.active = false
        binding
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
          workspace: configured_workspace(root: root, strict: worktree&.active? == true),
          provider: current_model_provider,
          model: current_model_id,
          reasoning_effort: current_reasoning_effort
        )
        agent = build_tab_agent(conversation, session, worktree: worktree)
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

      def handle_worktree_command(argument)
        case argument.to_s.strip
        when "", "toggle"
          toggle_active_tab_worktree
        when "status"
          print_active_worktree_status
        when "remove"
          remove_active_worktree
        else
          runtime_output("Usage: /tab worktree [status|remove]")
        end
      end

      def toggle_active_tab_worktree
        tab = active_tab
        return runtime_output("There is no active tab.") unless tab
        return runtime_output("Worktrees are available only for normal session tabs.") if plugin_tab?(tab)
        return runtime_output("Tab #{active_tab_number} is running and cannot change workspaces yet.") if tab&.running? || tab&.local_busy? || tab&.shell

        binding = worktree_binding_for(tab)
        return detach_active_worktree(tab, binding) if binding&.active?
        return activate_existing_worktree(tab, binding) if binding

        attach_new_worktree(tab)
      rescue GitWorktreeManager::Error, Sandbox::UnavailableError => e
        runtime_output("Worktree error: #{e.message}")
      end

      def attach_new_worktree(tab)
        origin_root = tab.agent.conversation.workspace_root
        repository_root = git_worktree_manager.repository_root(origin_root)
        status = git_worktree_manager.status(origin_root)
        if status.dirty? && !confirm_worktree_action(<<~MESSAGE)
          #{origin_root} has #{status.entries.length} local change(s).

          The new worktree will be created from HEAD. Existing changes will remain in the original workspace and will not be copied.

          Create the worktree anyway?
        MESSAGE
          return
        end

        branch = generated_worktree_branch(tab)
        path = default_worktree_path(repository_root, branch)
        binding = git_worktree_manager.create(
          repository_root: repository_root,
          origin_root: origin_root,
          path: path,
          branch: branch
        )
        begin
          rebind_active_tab(tab, root: binding.path, worktree: binding)
        rescue StandardError
          git_worktree_manager.remove(repository_root: binding.repository_root, path: binding.path)
          raise
        end
        runtime_output("Tab #{active_tab_number} is now using #{binding.branch} at #{binding.path}.")
      end

      def activate_existing_worktree(tab, binding)
        binding.active = true
        validate_worktree_binding!(binding)
        rebind_active_tab(tab, root: binding.path, worktree: binding)
        runtime_output("Tab #{active_tab_number} is now using #{binding.branch} at #{binding.path}.")
      rescue StandardError
        binding.active = false
        raise
      end

      def detach_active_worktree(tab, binding)
        validate_worktree_binding!(binding)
        status = git_worktree_manager.status(binding.path)
        if status.dirty? && !confirm_worktree_action(<<~MESSAGE)
          #{binding.path} has #{status.entries.length} local change(s).

          They will remain in the worktree after this tab switches back to #{binding.origin_root}.

          Detach and keep the worktree?
        MESSAGE
          return
        end

        binding.active = false
        rebind_active_tab(tab, root: binding.origin_root, worktree: binding)
        runtime_output("Tab #{active_tab_number} returned to #{binding.origin_root}; worktree kept at #{binding.path}.")
      rescue StandardError
        binding.active = true
        raise
      end

      def rebind_active_tab(tab, root:, worktree:)
        save_active_tab_state
        stop_tab_live_view
        rebind_session_tab(tab, root: root, worktree: worktree)
        activate_tab(@active_tab_index)
        persist_tabs
      end

      def print_active_worktree_status
        tab = active_tab
        binding = worktree_binding_for(tab)
        return runtime_output("Tab #{active_tab_number} has no worktree binding.") unless binding

        lines = [
          "Worktree: #{binding.active? ? "active" : "detached"}",
          "Origin: #{binding.origin_root}",
          "Path: #{binding.path}",
          "Branch: #{binding.branch}",
          "Base: #{binding.base_revision}"
        ]
        begin
          info = git_worktree_manager.inspect(repository_root: binding.repository_root, path: binding.path)
          raise GitWorktreeManager::Error, "Worktree branch changed: expected #{binding.branch}, found #{info.branch || "detached HEAD"}" unless info.branch == binding.branch
          status = git_worktree_manager.status(binding.path)
          lines << "Changes: #{status.clean? ? "clean" : "#{status.entries.length} local change(s)"}"
        rescue GitWorktreeManager::Error => e
          lines << "State: unavailable (#{e.message})"
        end
        runtime_output(lines.join("\n"))
      end

      def remove_active_worktree
        tab = active_tab
        binding = worktree_binding_for(tab)
        return runtime_output("Tab #{active_tab_number} has no worktree binding.") unless binding
        return runtime_output("Tab #{active_tab_number} is running and cannot remove its worktree yet.") if tab.running? || tab.local_busy? || tab.shell

        git_worktree_manager.inspect(repository_root: binding.repository_root, path: binding.path)
        status = git_worktree_manager.status(binding.path)
        return runtime_output("Worktree has local changes; detach it or clean it before removing it.") if status.dirty?

        was_active = binding.active?
        detached = false
        if was_active
          binding.active = false
          rebind_active_tab(tab, root: binding.origin_root, worktree: binding)
          detached = true
        end
        git_worktree_manager.remove(repository_root: binding.repository_root, path: binding.path)
        tab.driver = SessionTabDriver.new(session: tab.session, agent: tab.agent)
        tab.stream_state = new_tab_stream_state(tab.driver)
        persist_tabs
        runtime_output("Removed worktree #{binding.path}. Branch #{binding.branch} was kept.")
      rescue GitWorktreeManager::Error => e
        binding.active = true if was_active && !detached
        runtime_output("Worktree error: #{e.message}")
      end

      def confirm_worktree_action(message)
        @prompt.respond_to?(:yes?) && @prompt.yes?(message, default: false)
      end

      def generated_worktree_branch(tab)
        label = tab.label.to_s.downcase.gsub(/[^a-z0-9]+/, "-").sub(/\A-+|-+\z/, "")
        label = "tab-#{active_tab_number}" if label.empty?
        "kward/#{label}-#{SecureRandom.hex(3)}"
      end

      def default_worktree_path(repository_root, branch)
        slug = branch.to_s.delete_prefix("kward/").gsub(/[^a-zA-Z0-9._-]+/, "-")
        File.join(File.dirname(repository_root), ".kward-worktrees", File.basename(repository_root), slug)
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

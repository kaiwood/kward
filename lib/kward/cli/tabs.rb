# Namespace for the Kward CLI agent runtime.
module Kward
  # Command-line frontend that coordinates terminal interaction, sessions, tools, and model turns.
  class CLI
    # TUI session tab coordination.
    module Tabs
      private

      def setup_interactive_tabs(session_store, agent)
        @tabs = []
        @active_tab_index = 0
        @tab_store = session_store ? TabStore.new(cwd: session_store.cwd) : nil
        if session_store && agent.nil?
          restored = restore_tabs(session_store)
          return restored if restored
        end

        tab_agent = agent || build_new_session_agent(session_store)
        @tabs << build_tab(@active_session, tab_agent)
        update_prompt_tabs
        persist_tabs
        tab_agent
      end

      def restore_tabs(session_store)
        data = @tab_store&.load || {}
        paths = Array(data["session_paths"]).select { |path| File.file?(path.to_s) }
        return nil if paths.empty?

        paths.each do |path|
          session, conversation = session_store.load(path, workspace: configured_workspace(root: session_store.cwd), provider: current_model_provider, model: current_model_id, reasoning_effort: current_reasoning_effort)
          track_session(session)
          @tabs << build_tab(session, build_interactive_agent(conversation))
        rescue StandardError
          next
        end
        return nil if @tabs.empty?

        @active_tab_index = [[data["active_index"].to_i, 0].max, @tabs.length - 1].min
        activate_tab(@active_tab_index, render: false)
      end

      def build_tab(session, agent)
        {
          session: session,
          agent: agent,
          diff: session&.path ? SessionDiff.from_session_file(session.path) : SessionDiff.new,
          snapshot: nil
        }
      end

      def active_tab
        @tabs && @tabs[@active_tab_index]
      end

      def handle_tab_action(action, session_store)
        case action[:tab_action]
        when :new
          open_new_tab(session_store)
        when :close
          close_active_tab
        when :next
          switch_tab((@active_tab_index + 1) % @tabs.length) if @tabs && @tabs.length > 1
        when :previous
          switch_tab((@active_tab_index - 1) % @tabs.length) if @tabs && @tabs.length > 1
        when :select
          switch_tab(action[:index].to_i) if @tabs && action[:index].to_i < @tabs.length
        end
      end

      def open_new_tab(session_store)
        return say_sessions_unavailable unless session_store

        save_active_tab_state
        session = track_session(session_store.create(provider: current_model_provider, model: current_model_id, reasoning_effort: current_reasoning_effort))
        conversation = new_conversation(workspace_root: session_store.cwd)
        session.attach(conversation)
        @tabs << build_tab(session, build_interactive_agent(conversation))
        @active_tab_index = @tabs.length - 1
        activate_tab(@active_tab_index)
      end

      def close_active_tab
        if @tabs.length <= 1
          @tabs.clear
          persist_tabs
          return PromptInterface::EXIT_INPUT
        end

        tab = active_tab
        tab[:session]&.delete_if_unused if tab && tab[:session].respond_to?(:delete_if_unused)
        @tabs.delete_at(@active_tab_index)
        @active_tab_index = [@active_tab_index, @tabs.length - 1].min
        activate_tab(@active_tab_index)
        nil
      end

      def switch_tab(index)
        return if index == @active_tab_index
        return unless index.between?(0, @tabs.length - 1)

        save_active_tab_state
        @active_tab_index = index
        activate_tab(index)
      end

      def save_active_tab_state
        tab = active_tab
        return unless tab

        tab[:snapshot] = @prompt.composer_snapshot if @prompt.respond_to?(:composer_snapshot)
        tab[:diff] = @session_diff
      end

      def activate_tab(index, render: true)
        tab = @tabs[index]
        return nil unless tab

        @active_session = tab[:session]
        @session_diff = tab[:diff] || SessionDiff.new
        @footer_conversation = tab[:agent].conversation
        update_assistant_prompt(tab[:agent].conversation)
        update_prompt_tabs
        if render && @prompt.respond_to?(:restore_composer_snapshot)
          if tab[:snapshot]
            @prompt.restore_composer_snapshot(tab[:snapshot])
          else
            restore_prompt_transcript { render_conversation_transcript(tab[:agent].conversation) }
          end
        end
        persist_tabs
        tab[:agent]
      end

      def update_prompt_tabs
        return unless @prompt.respond_to?(:update_tabs)

        @prompt.update_tabs(labels: @tabs.each_index.map { |index| (index + 1).to_s }, active_index: @active_tab_index)
      end

      def persist_tabs
        return unless @tab_store

        @tab_store.save(
          session_paths: @tabs.map { |tab| tab[:session]&.path }.compact,
          active_index: @active_tab_index
        )
      end
    end
  end
end

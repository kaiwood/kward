module Kward
  class CLI
    module Sessions
      private

      def interactive_session_store(agent)
        return @session_store if @session_store
        return nil if agent

        SessionStore.new
      end

      def resume_last_session(session_store)
        return nil unless session_auto_resume_enabled?

        path = session_store.remembered_last_session_path if session_store.respond_to?(:remembered_last_session_path)
        return nil if path.to_s.empty?

        @active_session, conversation = session_store.load(path, workspace: configured_workspace(root: session_store.cwd), model: current_model_id, reasoning_effort: current_reasoning_effort)
        reset_session_diff(@active_session.path)
        track_session(@active_session)
        @resumed_last_session = true
        build_interactive_agent(conversation)
      rescue StandardError
        nil
      end

      def render_resumed_last_session_transcript(conversation)
        restore_prompt_transcript do
          @prompt.say("\nResumed session: #{@active_session.path}\n")
          render_conversation_transcript(conversation)
        end
      end

      def remember_active_session(session_store)
        return unless session_store&.respond_to?(:remember_last_session)
        return unless @active_session&.path && File.file?(@active_session.path)

        session_store.remember_last_session(@active_session)
      end

      def build_new_session_agent(session_store)
        @active_session = track_session(session_store.create(model: current_model_id, reasoning_effort: current_reasoning_effort))
        reset_session_diff
        conversation = new_conversation(workspace_root: session_store.cwd)
        @active_session.attach(conversation)
        build_interactive_agent(conversation)
      end

      def track_session(session)
        @cleanup_sessions << session if session
        session
      end

      def reset_session_diff(path = nil)
        @session_diff = path ? SessionDiff.from_session_file(path) : SessionDiff.new
      end

      def update_session_diff(content, tool_call: nil)
        return unless mutation_tool_call?(tool_call)
        return unless @session_diff&.add_tool_result(content)

        @prompt.redraw if @prompt.respond_to?(:redraw)
      end

      def mutation_tool_call?(tool_call)
        ["edit_file", "write_file", "edit", "write"].include?(ToolCall.name(tool_call).to_s)
      end

      def cleanup_unused_sessions
        @cleanup_sessions.reverse_each do |session|
          session.delete_if_unused if session.respond_to?(:delete_if_unused)
        end
        @cleanup_sessions.clear
      end

      def cleanup_replaced_session(previous_session)
        return unless previous_session
        return if @active_session && File.expand_path(previous_session.path) == File.expand_path(@active_session.path)

        previous_session.delete_if_unused if previous_session.respond_to?(:delete_if_unused)
      end

      def start_new_session(session_store)
        return say_sessions_unavailable unless session_store

        previous_session = @active_session
        @active_session = track_session(session_store.create)
        reset_session_diff
        cleanup_replaced_session(previous_session)
        conversation = new_conversation(workspace_root: session_store.cwd)
        @active_session.attach(conversation)
        update_assistant_prompt(conversation)
        clear_prompt_transcript
        print_visual_banner
        build_interactive_agent(conversation)
      end

      def resume_session(session_store, argument)
        return say_sessions_unavailable unless session_store

        path = argument.to_s.strip
        path = select_session_path(session_store) if path.empty?
        return nil if path.to_s.empty?

        previous_session = @active_session
        @active_session, conversation = session_store.load(path, workspace: configured_workspace(root: session_store.cwd), model: current_model_id, reasoning_effort: current_reasoning_effort)
        reset_session_diff(@active_session.path)
        track_session(@active_session)
        cleanup_replaced_session(previous_session)
        update_assistant_prompt(conversation)
        restore_prompt_transcript do
          @prompt.say("\nResumed session: #{@active_session.path}\n")
          render_conversation_transcript(conversation)
        end
        agent = build_interactive_agent(conversation)
        @prompt.redraw if @prompt.respond_to?(:redraw) && !@prompt.respond_to?(:restore_transcript)
        agent
      rescue StandardError => e
        @prompt.say("\nError: #{e.message}\n")
        nil
      end

      def navigate_session_tree(session_store)
        return say_sessions_unavailable unless session_store
        unless @active_session
          @prompt.say("\nNo active persisted session.\n")
          return nil
        end

        tree_items = session_tree_items(session_store)
        if tree_items.empty?
          @prompt.say("\nNo session tree entries found.\n")
          return nil
        end

        labels_by_entry_id = tree_items.to_h { |item| [item[:entry]["id"].to_s, item[:label]] }
        current_leaf_id = @active_session.leaf_id || session_store.current_leaf(@active_session.path)
        initial_index = tree_items.index { |item| item[:entry]["id"].to_s == current_leaf_id.to_s } || tree_items.length - 1
        choice = select_session_tree_entry(labels_by_entry_id.values, initial_index: initial_index)
        return nil unless choice

        entry_id = labels_by_entry_id.key(choice)
        entry = tree_items.find { |item| item[:entry]["id"].to_s == entry_id }&.fetch(:entry)
        return nil unless entry

        selected_text = apply_session_tree_entry(entry)
        @prompt.say("\nMoved session tree position to #{entry["id"]}.\n")
        if selected_text && !selected_text.empty?
          if @prompt.respond_to?(:prefill_input)
            @prompt.prefill_input(selected_text)
          else
            @prompt.say("\nSelected text for editing:\n#{selected_text}\n")
          end
        end
        agent = reload_active_session(session_store)
        @prompt.redraw if @prompt.respond_to?(:redraw)
        agent
      rescue StandardError => e
        @prompt.say("\nSession tree error: #{e.message}\n")
        nil
      end

      def select_session_tree_entry(labels, initial_index: 0)
        if @prompt.respond_to?(:select)
          return @prompt.select("Tree>", labels, title: "Session Tree", initial_index: initial_index)
        end

        numbered_labels = labels.each_with_index.map { |label, index| "#{index + 1}. #{label}" }
        @prompt.say("\nSession tree:\n#{numbered_labels.join("\n")}\n")
        answer = @prompt.ask("Tree entry number>").to_s.strip
        answer.match?(/\A\d+\z/) ? labels[answer.to_i - 1] : nil
      end

      def apply_session_tree_entry(entry)
        message = entry["message"]
        if message.is_a?(Hash) && message_role(message) == "user"
          target_leaf = entry["parentId"]
          target_leaf.to_s.empty? ? @active_session.reset_leaf : @active_session.branch(target_leaf)
          return full_message_text(message)
        end

        @active_session.branch(entry["id"])
        nil
      end

      def reload_active_session(session_store)
        @active_session, conversation = session_store.load(
          @active_session.path,
          workspace: configured_workspace(root: session_store.cwd),
          model: current_model_id,
          reasoning_effort: current_reasoning_effort
        )
        reset_session_diff(@active_session.path)
        track_session(@active_session)
        update_assistant_prompt(conversation)
        restore_prompt_transcript do
          render_conversation_transcript(conversation)
        end
        build_interactive_agent(conversation)
      end

      def session_tree_items(session_store)
        roots = session_store.session_tree(@active_session.path)
        current_leaf_id = @active_session.leaf_id || session_store.current_leaf(@active_session.path)
        SessionTreeRenderer.new(roots: roots, current_leaf_id: current_leaf_id).items
      end

      def rename_session(argument)
        unless @active_session
          @prompt.say("\nNo active persisted session.\n")
          return
        end

        @active_session.rename(argument)
        label = @active_session.name ? "Named session: #{@active_session.name}" : "Cleared session name."
        @prompt.say("\n#{label}\n")
      end

      def clone_session(session_store, agent)
        return say_sessions_unavailable unless session_store

        previous_session = @active_session
        @active_session = track_session(session_store.create_from_conversation(agent.conversation, parent_session: previous_session))
        reset_session_diff(@active_session.path)
        cleanup_replaced_session(previous_session)
        @prompt.say("\nCloned session: #{@active_session.path}\n")
        render_conversation_transcript(agent.conversation)
        agent
      end

      def copy_session_text(conversation, argument)
        target = copy_target(argument)
        unless target
          @prompt.say("\nUsage: /copy [last|transcript]\n")
          return
        end

        content = copy_target_content(conversation, target)
        if content.to_s.empty?
          @prompt.say("\nNothing to copy.\n")
          return
        end

        result = Clipboard.new(output: $stdout).copy(content)
        if result.success?
          @prompt.say("\nCopied #{copy_target_label(target)}.\n")
        else
          @prompt.say("\nCopy failed: #{result.message}.\n")
        end
      end

      def copy_target(argument)
        target = argument.to_s.strip.downcase
        target = "last" if target.empty?
        return target if ["last", "transcript"].include?(target)

        nil
      end

      def full_message_text(message)
        CLITranscriptFormatter.full_text(message)
      end

      def copy_target_content(conversation, target)
        case target
        when "last"
          last_assistant_copy_text(conversation)
        when "transcript"
          markdown_transcript(conversation)
        else
          ""
        end
      end

      def last_assistant_copy_text(conversation)
        message = conversation.messages.reverse.find { |item| message_role(item) == "assistant" }
        return "" unless message

        CLITranscriptFormatter.content_text(message_content(message))
      end

      def copy_target_label(target)
        target == "transcript" ? "transcript" : "last assistant response"
      end

      def export_session(conversation, argument)
        path = export_path(argument)
        File.write(path, markdown_transcript(conversation))
        @prompt.say("\nExported session: #{path}\n")
      rescue StandardError => e
        @prompt.say("\nError: #{e.message}\n")
      end

      def say_sessions_unavailable
        @prompt.say("\nSessions are unavailable for this interactive loop.\n")
        nil
      end

      def clear_prompt_transcript
        @prompt.clear_transcript if @prompt.respond_to?(:clear_transcript)
      end

      def restore_prompt_transcript(&block)
        if @prompt.respond_to?(:restore_transcript)
          @prompt.restore_transcript(&block)
        else
          block.call
        end
      end

      def select_session_path(session_store)
        sessions = session_store.recent(limit: nil)
        if sessions.empty?
          @prompt.say("\nNo saved sessions found.\n")
          return nil
        end

        labels = sessions.map { |session| session_label(session) }
        if @prompt.respond_to?(:select)
          choice = @prompt.select("Session>", labels)
          return nil unless choice

          selected = sessions[labels.index(choice)]
          return selected&.path
        end

        numbered_labels = labels.each_with_index.map { |label, index| "#{index + 1}. #{label}" }
        @prompt.say("\nRecent sessions:\n#{numbered_labels.join("\n")}\n")
        answer = @prompt.ask("Session number or path>").to_s.strip
        if answer.match?(/\A\d+\z/)
          sessions[answer.to_i - 1]&.path
        else
          answer
        end
      end

      def session_label(session)
        title = session.name.to_s.strip
        title = session.first_message.to_s.strip if title.empty?
        title = session.id if title.empty?
        "#{session_tree_prefix(session)}#{title} — #{File.basename(session.path)}"
      end

      def session_tree_prefix(session)
        depth = session.respond_to?(:depth) ? session.depth.to_i : 0
        return "" if depth <= 0

        ancestors = session.respond_to?(:ancestor_continues) ? Array(session.ancestor_continues) : []
        prefix = ancestors.map { |continues| continues ? "│  " : "   " }.join
        branch = session.respond_to?(:is_last) && session.is_last ? "└─ " : "├─ "
        prefix + branch
      end

      def export_path(argument)
        default_path = if @active_session
                         @active_session.path.sub(/\.jsonl\z/, ".md")
                       else
                         File.expand_path("kward-session-#{Time.now.utc.iso8601(3).tr(':', '-')}.md", Dir.pwd)
                       end
        session_dir = @session_store&.session_dir || (@active_session && File.dirname(@active_session.path))

        ExportPath.resolve(argument, workspace_root: Dir.pwd, default_path: default_path, session_dir: session_dir)
      end

      def markdown_transcript(conversation)
        TranscriptExport.content(conversation)
      end

    end
  end
end

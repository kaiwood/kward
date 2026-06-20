require "time"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Command-line frontend that coordinates terminal interaction, sessions, tools, and model turns.
  class CLI
    # Interactive session list, resume, clone, tree, export, and copy helpers.
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

        @active_session, conversation = session_store.load(path, workspace: configured_workspace(root: session_store.cwd), provider: current_model_provider, model: current_model_id, reasoning_effort: current_reasoning_effort)
        reset_session_diff(@active_session.path)
        track_session(@active_session)
        @resumed_last_session = true
        build_interactive_agent(conversation)
      rescue StandardError
        nil
      end

      def render_resumed_last_session_transcript(conversation)
        restore_prompt_transcript do
          runtime_output("Resumed session: #{@active_session.path}")
          render_conversation_transcript(conversation)
        end
      end

      def remember_active_session(session_store)
        return unless session_store&.respond_to?(:remember_last_session)
        return unless @active_session&.path && File.file?(@active_session.path)

        session_store.remember_last_session(@active_session)
      end

      def build_new_session_agent(session_store)
        @active_session = track_session(session_store.create(provider: current_model_provider, model: current_model_id, reasoning_effort: current_reasoning_effort))
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

        load_session(session_store, path, message: "Resumed session")
      rescue StandardError => e
        runtime_output("Error: #{e.message}")
        nil
      end

      def load_session(session_store, path, message: nil)
        previous_session = @active_session
        @active_session, conversation = session_store.load(path, workspace: configured_workspace(root: session_store.cwd), provider: current_model_provider, model: current_model_id, reasoning_effort: current_reasoning_effort)
        reset_session_diff(@active_session.path)
        track_session(@active_session)
        cleanup_replaced_session(previous_session)
        update_assistant_prompt(conversation)
        restore_prompt_transcript do
          runtime_output("#{message}: #{@active_session.path}") if message
          render_conversation_transcript(conversation)
        end
        agent = build_interactive_agent(conversation)
        @prompt.redraw if @prompt.respond_to?(:redraw) && !@prompt.respond_to?(:restore_transcript)
        agent
      end

      def navigate_session_tree(session_store)
        return say_sessions_unavailable unless session_store
        unless @active_session
          runtime_output("No active persisted session.")
          return nil
        end

        tree_items = run_busy_local_command_and_requeue { session_tree_items(session_store) }
        if tree_items.empty?
          runtime_output("No session tree entries found.")
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

        selected_text = nil
        agent = run_busy_local_command_and_requeue do
          selected_text = apply_session_tree_entry(entry)
          runtime_output("Moved session tree position to #{entry["id"]}.")
          reload_active_session(session_store)
        end
        if selected_text && !selected_text.empty?
          if @prompt.respond_to?(:prefill_input)
            @prompt.prefill_input(selected_text)
          else
            runtime_output("Selected text for editing:\n#{selected_text}")
          end
        end
        @prompt.redraw if @prompt.respond_to?(:redraw) && !@prompt.respond_to?(:restore_transcript)
        agent
      rescue StandardError => e
        runtime_output("Session tree error: #{e.message}")
        nil
      end

      def select_session_tree_entry(labels, initial_index: 0)
        if @prompt.respond_to?(:select)
          return @prompt.select("Tree>", labels, title: "Session Tree", initial_index: initial_index)
        end

        numbered_labels = labels.each_with_index.map { |label, index| "#{index + 1}. #{label}" }
        runtime_output((["Session tree:"] + numbered_labels).join("\n"))
        answer = @prompt.ask("Tree entry number>").to_s.strip
        answer.match?(/\A\d+\z/) ? labels[answer.to_i - 1] : nil
      end

      def rewind_session(session_store)
        return say_sessions_unavailable unless session_store
        unless @active_session
          runtime_output("No active persisted session.")
          return nil
        end

        points = rewind_points(session_store)
        if points.empty?
          runtime_output("No prompts to rewind to.")
          return nil
        end

        labels = points.map { |point| point[:label] }
        choice = select_rewind_point(labels)
        return nil unless choice

        point = points[labels.index(choice)]
        return nil unless point

        if point[:return_leaf_id]
          @active_session.branch(point[:return_leaf_id])
          @rewind_return_leaf_id = nil
        else
          @rewind_return_leaf_id = @active_session.leaf_id || session_store.current_leaf(@active_session.path)
          selected_text = apply_session_tree_entry(point[:entry])
          if selected_text && !selected_text.empty?
            if @prompt.respond_to?(:prefill_input)
              @prompt.prefill_input(selected_text)
            else
              runtime_output("Selected prompt for editing:\n#{selected_text}")
            end
          end
        end
        agent = reload_active_session(session_store)
        @prompt.redraw if @prompt.respond_to?(:redraw)
        agent
      rescue StandardError => e
        runtime_output("Rewind error: #{e.message}")
        nil
      end

      def select_rewind_point(labels)
        if @prompt.respond_to?(:select)
          return @prompt.select("Rewind>", labels, title: "Rewind")
        end

        numbered_labels = labels.each_with_index.map { |label, index| "#{index + 1}. #{label}" }
        runtime_output((["Rewind to:"] + numbered_labels).join("\n"))
        answer = @prompt.ask("Rewind point number>").to_s.strip
        answer.match?(/\A\d+\z/) ? labels[answer.to_i - 1] : nil
      end

      def rewind_points(session_store)
        entries = session_store.session_entries(@active_session.path)
        current_leaf_id = @active_session.leaf_id || session_store.current_leaf(@active_session.path)
        active_path = active_session_tree_entry_ids(entries, current_leaf_id)
        user_entries = entries.select { |entry| rewind_entry?(entry) }
        points = user_entries.reverse_each.with_index.map do |entry, index|
          {
            entry: entry,
            label: rewind_point_label(entry, index, active_path.include?(entry["id"].to_s)),
            timestamp: entry["timestamp"]
          }
        end
        return_point = rewind_return_point(entries, current_leaf_id)
        points = [return_point] + points if return_point
        align_rewind_point_timestamps(points, picker_choice_width)
      end

      def rewind_return_point(entries, current_leaf_id)
        return nil if @rewind_return_leaf_id.to_s.empty?
        return nil if @rewind_return_leaf_id.to_s == current_leaf_id.to_s

        entry = entries.find { |candidate| candidate["id"].to_s == @rewind_return_leaf_id.to_s }
        return nil unless entry

        {
          return_leaf_id: @rewind_return_leaf_id,
          label: "Return to where I was: #{truncate_rewind_text(rewind_return_text(entry))}",
          timestamp: entry["timestamp"]
        }
      end

      def align_rewind_point_timestamps(points, width)
        labels = points.map { |point| point[:label].to_s }
        label_width = labels.map(&:length).max.to_i
        points.each do |point|
          timestamp = relative_rewind_time(point[:timestamp])
          next if timestamp.empty?

          point[:label] = right_aligned_picker_metadata(point[:label], timestamp, width: width, minimum_label_width: label_width)
        end
      end

      def right_aligned_picker_metadata(label, metadata, width:, minimum_label_width: 0)
        label = label.to_s
        metadata = metadata.to_s
        fallback_width = minimum_label_width + metadata.length + 2
        target_width = width.to_i.positive? ? width.to_i : fallback_width
        label_width = [target_width - metadata.length - 2, 1].max
        "#{truncate_picker_label(label, label_width).ljust(label_width)}  #{metadata}"
      end

      def truncate_picker_label(label, width)
        return "" if width <= 0

        text = label.to_s
        return text if text.length <= width
        return text.slice(0, width) if width <= 3

        "#{text.slice(0, width - 3)}..."
      end

      def relative_rewind_time(timestamp)
        time = timestamp.is_a?(Time) ? timestamp.utc : Time.iso8601(timestamp.to_s).utc
        seconds = [(Time.now.utc - time).to_i, 0].max
        case seconds
        when 0...60
          "just now"
        when 60...3600
          minutes = seconds / 60
          "#{minutes} min ago"
        when 3600...86_400
          hours = seconds / 3600
          "#{hours} h ago"
        else
          days = seconds / 86_400
          "#{days} d ago"
        end
      rescue ArgumentError
        ""
      end

      def rewind_return_text(entry)
        message = entry["message"]
        text = full_message_text(message) if message.is_a?(Hash)
        text.to_s.empty? ? entry["id"].to_s : text
      end

      def rewind_entry?(entry)
        return false unless entry["type"] == "message"

        message = entry["message"]
        message.is_a?(Hash) && message_role(message) == "user" && !full_message_text(message).empty?
      end

      def rewind_point_label(entry, index, active)
        marker = active ? "• " : ""
        prefix = case index
                 when 0 then "Last prompt"
                 when 1 then "2 turns ago"
                 else "#{index + 1} turns ago"
                 end
        "#{marker}#{prefix}: #{truncate_rewind_text(full_message_text(entry["message"] || {}))}"
      end

      def active_session_tree_entry_ids(entries, leaf_id)
        by_id = entries.to_h { |entry| [entry["id"].to_s, entry] }
        ids = []
        seen = {}
        current = by_id[leaf_id.to_s]
        while current && !seen[current["id"].to_s]
          seen[current["id"].to_s] = true
          ids << current["id"].to_s
          current = by_id[current["parentId"].to_s]
        end
        ids
      end

      def truncate_rewind_text(text)
        text.to_s.gsub(/\s+/, " ").strip
      end

      def picker_choice_width
        if @prompt.respond_to?(:picker_choice_width)
          @prompt.picker_choice_width
        else
          96
        end
      end

      def apply_session_tree_entry(entry)
        message = entry["message"]
        if message.is_a?(Hash) && message_role(message) == "user"
          target_leaf = entry["parentId"]
          @active_session.branch(target_leaf) unless target_leaf.to_s.empty?
          return full_message_text(message)
        end

        @active_session.branch(entry["id"])
        nil
      end

      def reload_active_session(session_store)
        @active_session, conversation = session_store.load(
          @active_session.path,
          workspace: configured_workspace(root: session_store.cwd),
          provider: current_model_provider,
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
          runtime_output("No active persisted session.")
          return
        end

        @active_session.rename(argument)
        label = @active_session.name ? "Named session: #{@active_session.name}" : "Cleared session name."
        runtime_output(label)
      end

      def clone_session(session_store, agent)
        return say_sessions_unavailable unless session_store

        previous_session = @active_session
        @active_session = track_session(session_store.create_from_conversation(agent.conversation, parent_session: previous_session))
        reset_session_diff(@active_session.path)
        cleanup_replaced_session(previous_session)
        runtime_output("Cloned session: #{@active_session.path}")
        render_conversation_transcript(agent.conversation)
        agent
      end

      def clone_session_from_path(session_store, path)
        clone_path = clone_session_file_from_path(session_store, path)
        load_session(session_store, clone_path, message: "Cloned session")
      end

      def clone_session_file_from_path(session_store, path)
        source_session, source_conversation = session_store.load(path, workspace: configured_workspace(root: session_store.cwd), provider: current_model_provider, model: current_model_id, reasoning_effort: current_reasoning_effort)
        clone, = session_store.create_independent_from_conversation(source_conversation, parent_session: source_session)
        clone.path
      end

      def clone_session_selection(session_store, sessions, labels, label)
        source = sessions[labels.index(label)]
        return nil unless source

        clone_path = clone_session_file_from_path(session_store, source.path)
        clone_info = session_store.recent_tree(limit: nil).find { |session| File.expand_path(session.path) == File.expand_path(clone_path) }
        clone_info ||= session_store.recent(limit: nil).find { |session| File.expand_path(session.path) == File.expand_path(clone_path) }
        return nil unless clone_info

        source_index = sessions.index(source) || 0
        clone_index = source_index + 1
        sessions.insert(clone_index, clone_info)
        labels.replace(session_picker_labels(sessions))
        label = labels[clone_index]
        { select_continue: true, choices: labels, selection_index: clone_index, action_choices: { label => { action: :cloned, path: clone_path } } }
      end

      def delete_session_selection(_session_store, sessions, labels, label)
        source = sessions[labels.index(label)]
        return nil unless source

        SessionTrash.new.delete(source.path)
        index = sessions.index(source) || labels.index(label) || 0
        sessions.delete_at(index)
        labels.replace(session_picker_labels(sessions))
        next_index = [index, labels.length - 1].min
        { select_continue: true, choices: labels, selection_index: next_index }
      end

      def copy_session_text(conversation, argument)
        target = copy_target(argument)
        unless target
          runtime_output("Usage: /copy [last|transcript]")
          return
        end

        content = copy_target_content(conversation, target)
        if content.to_s.empty?
          runtime_output("Nothing to copy.")
          return
        end

        result = Clipboard.new(output: $stdout).copy(content)
        if result.success?
          runtime_output("Copied #{copy_target_label(target)}.")
        else
          runtime_output("Copy failed: #{result.message}.")
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
        runtime_output("Exported session: #{path}")
      rescue StandardError => e
        runtime_output("Error: #{e.message}")
      end

      def say_sessions_unavailable
        runtime_output("Sessions are unavailable for this interactive loop.")
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
        select_session_path_from_sessions(session_store.recent_tree(limit: nil), session_store: session_store)
      end

      def select_session_path_from_sessions(sessions, session_store: @session_store)
        if sessions.empty?
          runtime_output("No saved sessions found.")
          return nil
        end

        labels = session_picker_labels(sessions)
        if @prompt.respond_to?(:select)
          choice = @prompt.select(
            "Session>",
            labels,
            action_keys: { "c" => { action: :clone, activity: "cloning" }, "d" => { action: :delete, confirm: "Press d again to delete, Esc to cancel.", confirm_title: "Delete session?" } },
            action_handlers: {
              clone: ->(label) { clone_session_selection(session_store, sessions, labels, label) },
              delete: ->(label) { delete_session_selection(session_store, sessions, labels, label) }
            }
          )
          return nil unless choice
          return choice if choice.respond_to?(:conversation)
          return choice if choice.is_a?(Hash)

          selected = sessions[labels.index(choice)]
          return selected&.path
        end

        numbered_labels = labels.each_with_index.map { |label, index| "#{index + 1}. #{label}" }
        runtime_output((["Recent sessions:"] + numbered_labels).join("\n"))
        answer = @prompt.ask("Session number or path>").to_s.strip
        if answer.match?(/\A\d+\z/)
          sessions[answer.to_i - 1]&.path
        else
          answer
        end
      end

      def session_selection_action(choice, sessions, labels)
        selected = sessions[labels.index(choice[:choice])]
        selected ? { action: choice[:action], path: selected.path } : nil
      end

      def session_picker_labels(sessions)
        labels = sessions.map { |session| session_label(session) }
        label_width = labels.map(&:length).max.to_i
        sessions.zip(labels).map do |session, label|
          timestamp = relative_rewind_time(session.modified_at)
          next label if timestamp.empty?

          right_aligned_picker_metadata(label, timestamp, width: picker_choice_width, minimum_label_width: label_width)
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

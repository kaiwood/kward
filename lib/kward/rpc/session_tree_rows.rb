require_relative "../message_access"
require_relative "../message_text"
require_relative "../session_tree_tool_display"
require_relative "../tools/tool_call"

# Namespace for the Kward CLI agent runtime.
module Kward
  # JSON-RPC backend namespace used by UI clients.
  module RPC
    # Builds frontend-neutral RPC row payloads from a persisted session tree.
    #
    # `SessionManager` owns session lifecycle and decides when a tree is needed;
    # this class owns only the mechanics of flattening tree nodes into the row
    # fields sent over JSON-RPC. Keeping row presentation here prevents the RPC
    # session coordinator from accumulating rendering details while preserving the
    # exact Tauren-compatible payload shape.
    class SessionTreeRows
      # @param roots [Array<Hash>] tree roots returned by `SessionStore#session_tree`
      # @param current_leaf [String, nil] active persisted tree leaf id
      # @param selectable [#call] predicate receiving an entry hash
      def initialize(roots:, current_leaf:, selectable:)
        @roots = roots
        @current_leaf = current_leaf
        @selectable = selectable
      end

      # Returns flattened RPC row hashes in active-path-first display order.
      #
      # @return [Array<Hash>] rows for the `session/tree` RPC method
      def rows
        active_path = tree_active_path(@roots, @current_leaf)
        tool_calls_by_id = tree_tool_calls(@roots)
        visible_roots = @roots.flat_map { |root| visible_tree_nodes(root) }
        multiple_roots = visible_roots.length > 1
        result = []

        stack = visible_roots.sort_by { |root| tree_contains_active_path?(root, active_path) ? 0 : 1 }.each_with_index.map do |root, index|
          [root, multiple_roots ? 1 : 0, multiple_roots, multiple_roots, index == visible_roots.length - 1, [], multiple_roots]
        end.reverse

        until stack.empty?
          node, indent, just_branched, show_connector, is_last, gutters, virtual_root_child = stack.pop
          entry = node[:source]["entry"] || {}
          entry_id = entry["id"].to_s
          formatted = tree_entry_display(entry, tool_calls_by_id)
          display_indent = multiple_roots ? [indent - 1, 0].max : indent
          result << {
            entryId: entry_id,
            parentId: entry["parentId"],
            role: formatted[:role],
            text: formatted[:text],
            current: !@current_leaf.to_s.empty? && entry_id == @current_leaf.to_s,
            depth: display_indent,
            isLast: is_last,
            ancestorContinues: gutters.map { |gutter| gutter[:show] },
            activePath: active_path.include?(entry_id),
            selectable: @selectable.call(entry),
            label: node[:source]["label"] || entry["resolvedLabel"],
            labelTimestamp: node[:source]["labelTimestamp"],
            prefix: tree_prefix(display_indent, gutters, show_connector && !virtual_root_child, is_last, !node[:children].empty?)
          }.compact

          children = node[:children].sort_by { |child| tree_contains_active_path?(child, active_path) ? 0 : 1 }
          multiple_children = children.length > 1
          child_indent = if multiple_children
                           indent + 1
                         elsif just_branched && indent.positive?
                           indent + 1
                         else
                           indent
                         end
          connector_position = [display_indent - 1, 0].max
          child_gutters = show_connector && !virtual_root_child ? gutters + [{ position: connector_position, show: !is_last }] : gutters
          children.each_with_index.reverse_each do |child, index|
            stack << [child, child_indent, multiple_children, multiple_children, index == children.length - 1, child_gutters, false]
          end
        end
        result
      end

      private

      def tree_active_path(roots, leaf_id)
        by_id = tree_entries_by_id(roots)
        ids = []
        current = by_id[leaf_id.to_s]
        seen = {}
        while current && !seen[current["id"].to_s]
          seen[current["id"].to_s] = true
          ids << current["id"].to_s
          current = by_id[current["parentId"].to_s]
        end
        ids
      end

      def tree_entries_by_id(roots)
        roots.each_with_object({}) do |root, map|
          stack = [root]
          seen = {}
          until stack.empty?
            node = stack.pop
            next if seen[node.object_id]

            seen[node.object_id] = true
            entry = node["entry"] || {}
            map[entry["id"].to_s] = entry unless entry["id"].to_s.empty?
            stack.concat(Array(node["children"]))
          end
        end
      end

      def visible_tree_nodes(node)
        results = {}
        stack = [[node, false, {}]]

        until stack.empty?
          current, visited, seen = stack.pop
          node_key = current.object_id
          next if seen[node_key]

          if visited
            children = Array(current["children"]).flat_map { |child| results[child.object_id] || [] }
            results[node_key] = if hidden_tree_entry?(current["entry"] || {})
                                  children
                                else
                                  [{ source: current, children: children }]
                                end
          else
            branch_seen = seen.merge(node_key => true)
            stack << [current, true, seen]
            Array(current["children"]).reverse_each { |child| stack << [child, false, branch_seen] unless branch_seen[child.object_id] }
          end
        end

        results[node.object_id] || []
      end

      def hidden_tree_entry?(entry)
        return false if @current_leaf && entry["id"].to_s == @current_leaf.to_s
        return false unless entry["type"] == "message"

        message = entry["message"]
        return false unless message.is_a?(Hash) && MessageAccess.role(message) == "assistant"

        content = MessageAccess.content(message)
        content_tool_calls = content.is_a?(Array) && content.any? { |part| ToolCall.value(part, :type) == "toolCall" }
        (content_tool_calls && !tree_text_content?(content)) || (!MessageAccess.tool_calls(message).empty? && MessageText.full_text(message).empty?)
      end

      def tree_text_content?(content)
        Array(content).any? { |part| ToolCall.value(part, :type) == "text" && ToolCall.value(part, :text).to_s.strip != "" }
      end

      def tree_contains_active_path?(node, active_path)
        stack = [node]
        seen = {}
        until stack.empty?
          current = stack.pop
          next if seen[current.object_id]

          seen[current.object_id] = true
          entry_id = (current[:source]["entry"] || {})["id"].to_s
          return true if active_path.include?(entry_id)

          stack.concat(current[:children])
        end
        false
      end

      def tree_tool_calls(roots)
        roots.each_with_object({}) do |root, tool_calls_by_id|
          stack = [root]
          seen = {}
          until stack.empty?
            node = stack.pop
            next if seen[node.object_id]

            seen[node.object_id] = true
            entry = node["entry"] || {}
            message = entry["message"]
            if entry["type"] == "message" && message.is_a?(Hash) && MessageAccess.role(message) == "assistant"
              MessageAccess.tool_calls(message).each { |tool_call| tool_calls_by_id[ToolCall.id(tool_call).to_s] = tool_call }
            end
            stack.concat(Array(node["children"]))
          end
        end
      end

      def tree_entry_display(entry, tool_calls_by_id = {})
        case entry["type"]
        when "message"
          message = entry["message"] || {}
          role = MessageAccess.role(message).to_s
          return { role: "tool", text: format_tool_result(message, tool_calls_by_id) } if ["tool", "toolResult"].include?(role)
          return { role: role.empty? ? "message" : role, text: display_message_text(message) }
        when "compaction"
          return { role: "compaction", text: display_message_text(entry["message"] || {}) }
        when "branch_summary"
          return { role: "summary", text: truncate_tree_text(entry["summary"]) }
        end

        { role: entry["type"].to_s.empty? ? "entry" : entry["type"].to_s, text: entry["type"].to_s }
      end

      def tree_prefix(display_indent, gutters, show_connector, is_last, foldable)
        return "" if display_indent.to_i <= 0

        connector_position = show_connector ? display_indent - 1 : -1
        (0...(display_indent * 3)).map do |index|
          level = index / 3
          position = index % 3
          gutter = gutters.find { |candidate| candidate[:position] == level }

          if gutter
            position.zero? && gutter[:show] ? "│" : " "
          elsif show_connector && level == connector_position
            if position.zero?
              is_last ? "└" : "├"
            elsif position == 1
              foldable ? "⊟" : "─"
            else
              " "
            end
          else
            " "
          end
        end.join
      end

      def format_tool_result(message, tool_calls_by_id)
        tool_call = tool_calls_by_id[MessageAccess.tool_call_id(message).to_s]
        return SessionTreeToolDisplay.label(tool_call) if tool_call

        name = MessageAccess.tool_name(message).to_s
        name = "tool" if name.empty?
        "[#{name}]"
      end

      def display_message_text(message)
        truncate_tree_text(MessageText.full_text(message))
      end

      def truncate_tree_text(text)
        normalized = text.to_s.gsub(/\s+/, " ").strip
        normalized.length > 120 ? "#{normalized.slice(0, 117)}..." : normalized
      end
    end
  end
end

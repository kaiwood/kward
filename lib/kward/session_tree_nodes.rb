require_relative "message_access"
require_relative "message_text"
require_relative "tools/tool_call"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Shared traversal helpers for persisted session trees.
  #
  # Frontends own their final labels or payloads. This class owns only the
  # frontend-neutral mechanics needed by both terminal and RPC tree views:
  # active-path lookup, hidden tool-call-only assistant nodes, visible-node
  # flattening, and assistant tool-call lookup by id.
  class SessionTreeNodes
    def initialize(roots:, current_leaf: nil)
      @roots = roots
      @current_leaf = current_leaf
    end

    def active_path
      by_id = entries_by_id
      ids = []
      entry = by_id[@current_leaf.to_s]
      seen = {}
      while entry && !seen[entry["id"].to_s]
        seen[entry["id"].to_s] = true
        ids << entry["id"].to_s
        entry = by_id[entry["parentId"].to_s]
      end
      ids
    end

    def visible_roots
      @roots.flat_map { |root| visible_nodes(root) }
    end

    def tool_calls
      @roots.each_with_object({}) do |root, calls|
        stack = [root]
        seen = {}
        until stack.empty?
          node = stack.pop
          next if seen[node.object_id]

          seen[node.object_id] = true
          entry = node["entry"] || {}
          message = entry["message"]
          if entry["type"] == "message" && message.is_a?(Hash) && MessageAccess.role(message) == "assistant"
            MessageAccess.tool_calls(message).each { |tool_call| calls[ToolCall.id(tool_call).to_s] = tool_call }
          end
          stack.concat(Array(node["children"]))
        end
      end
    end

    def layout_rows
      active = active_path
      roots = visible_roots
      active_nodes = active_node_lookup(roots, active)
      multiple_roots = roots.length > 1
      result = []

      stack = roots.sort_by { |root| active_nodes[root.object_id] ? 0 : 1 }.each_with_index.map do |root, index|
        [root, multiple_roots ? 1 : 0, multiple_roots, multiple_roots, index == roots.length - 1, [], multiple_roots]
      end.reverse

      until stack.empty?
        node, indent, just_branched, show_connector, is_last, gutters, virtual_root_child = stack.pop
        entry = node[:source]["entry"] || {}
        entry_id = entry["id"].to_s
        display_indent = multiple_roots ? [indent - 1, 0].max : indent
        show_node_connector = show_connector && !virtual_root_child

        result << {
          source: node[:source],
          entry: entry,
          depth: display_indent,
          is_last: is_last,
          gutters: gutters,
          active_path: active.include?(entry_id),
          prefix: self.class.tree_prefix(display_indent, gutters, show_node_connector, is_last, !node[:children].empty?)
        }

        children = node[:children].sort_by { |child| active_nodes[child.object_id] ? 0 : 1 }
        multiple_children = children.length > 1
        child_indent = if multiple_children
                         indent + 1
                       elsif just_branched && indent.positive?
                         indent + 1
                       else
                         indent
                       end
        connector_position = [display_indent - 1, 0].max
        child_gutters = show_node_connector ? gutters + [{ position: connector_position, show: !is_last }] : gutters

        children.each_with_index.reverse_each do |child, index|
          stack << [child, child_indent, multiple_children, multiple_children, index == children.length - 1, child_gutters, false]
        end
      end

      result
    end

    def self.tree_prefix(display_indent, gutters, show_connector, is_last, foldable)
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

    def self.truncate_text(text)
      MessageText.truncate_preview(text)
    end

    private

    def active_node_lookup(roots, active_path)
      active_ids = active_path.to_h { |id| [id, true] }
      lookup = {}
      stack = roots.map { |root| [root, false] }
      seen = {}

      until stack.empty?
        node, visited = stack.pop
        node_key = node.object_id
        if visited
          entry_id = (node[:source]["entry"] || {})["id"].to_s
          lookup[node_key] = active_ids[entry_id] || node[:children].any? { |child| lookup[child.object_id] }
        else
          next if seen[node_key]

          seen[node_key] = true
          stack << [node, true]
          node[:children].each { |child| stack << [child, false] }
        end
      end

      lookup
    end

    def visible_nodes(node)
      results = {}
      stack = [[node, false, {}]]

      until stack.empty?
        current, visited, seen = stack.pop
        node_key = current.object_id
        next if seen[node_key]

        if visited
          children = Array(current["children"]).flat_map { |child| results[child.object_id] || [] }
          results[node_key] = if hidden_entry?(current["entry"] || {})
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

    def hidden_entry?(entry)
      return false if @current_leaf && entry["id"].to_s == @current_leaf.to_s
      return false unless entry["type"] == "message"

      message = entry["message"]
      return false unless message.is_a?(Hash) && MessageAccess.role(message) == "assistant"

      content = MessageAccess.content(message)
      content_tool_calls = content.is_a?(Array) && content.any? { |part| MessageAccess.value(part, :type) == "toolCall" }
      (content_tool_calls && !text_content?(content)) || (!MessageAccess.tool_calls(message).empty? && MessageText.full_text(message).empty?)
    end

    def text_content?(content)
      Array(content).any? { |part| MessageAccess.value(part, :type) == "text" && MessageAccess.value(part, :text).to_s.strip != "" }
    end

    def entries_by_id
      @roots.each_with_object({}) do |root, map|
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
  end
end

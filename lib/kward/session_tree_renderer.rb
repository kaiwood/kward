require "json"
require_relative "message_access"
require_relative "message_text"
require_relative "tools/tool_call"

module Kward
  class SessionTreeRenderer
    def initialize(roots:, current_leaf_id:)
      @roots = roots
      @current_leaf_id = current_leaf_id
    end

    def items
      active_path = session_tree_active_path(@roots, @current_leaf_id)
      tool_calls_by_id = session_tree_tool_calls(@roots)
      visible_roots = @roots.flat_map { |root| visible_session_tree_nodes(root) }
      multiple_roots = visible_roots.length > 1
      result = []

      walk = lambda do |node, indent, just_branched, show_connector, is_last, gutters, virtual_root_child|
        entry = node[:source]["entry"] || {}
        display_indent = multiple_roots ? [indent - 1, 0].max : indent
        prefix = session_tree_visual_prefix(display_indent, gutters, show_connector && !virtual_root_child, is_last, !node[:children].empty?)
        result << {
          entry: entry,
          label: session_tree_label(entry, node[:source], prefix, active_path.include?(entry["id"].to_s), tool_calls_by_id)
        }

        children = node[:children].sort_by { |child| session_tree_contains_active_path?(child, active_path) ? 0 : 1 }
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

        children.each_with_index do |child, index|
          walk.call(child, child_indent, multiple_children, multiple_children, index == children.length - 1, child_gutters, false)
        end
      end

      visible_roots.sort_by { |root| session_tree_contains_active_path?(root, active_path) ? 0 : 1 }.each_with_index do |root, index|
        walk.call(root, multiple_roots ? 1 : 0, multiple_roots, multiple_roots, index == visible_roots.length - 1, [], multiple_roots)
      end

      result
    end

    private

    def visible_session_tree_nodes(node)
      children = Array(node["children"]).flat_map { |child| visible_session_tree_nodes(child) }
      return children if hidden_session_tree_entry?(node["entry"] || {})

      [{ source: node, children: children }]
    end

    def hidden_session_tree_entry?(entry)
      return false if @current_leaf_id && entry["id"].to_s == @current_leaf_id.to_s
      return false unless entry["type"] == "message"

      message = entry["message"]
      return false unless message.is_a?(Hash) && message_role(message) == "assistant"

      content = message_content(message)
      content_tool_calls = content.is_a?(Array) && content.any? { |part| session_tree_content_part_value(part, :type) == "toolCall" }
      (content_tool_calls && !session_tree_text_content?(content)) || (!message_tool_calls(message).empty? && full_message_text(message).empty?)
    end

    def session_tree_text_content?(content)
      Array(content).any? { |part| session_tree_content_part_value(part, :type) == "text" && session_tree_content_part_value(part, :text).to_s.strip != "" }
    end

    def session_tree_content_part_value(part, key)
      MessageAccess.value(part, key)
    end

    def session_tree_label(entry, node, prefix, active_path, tool_calls_by_id)
      label = node["label"] || entry["resolvedLabel"]
      label = label.to_s.strip
      label_text = label.empty? ? "" : "[#{label}] "
      path_marker = active_path ? "• " : ""
      "#{prefix}#{path_marker}#{label_text}#{session_tree_entry_display(entry, tool_calls_by_id)}"
    end

    def session_tree_entry_display(entry, tool_calls_by_id = {})
      case entry["type"]
      when "message"
        message = entry["message"] || {}
        role = message_role(message).to_s
        return session_tree_tool_display(message, tool_calls_by_id) if ["tool", "toolResult"].include?(role)

        "#{role.empty? ? 'message' : role}: #{display_message_text(message)}"
      when "compaction"
        "compaction: #{display_message_text(entry["message"] || {})}"
      when "branch_summary"
        "[branch summary]: #{truncate_session_tree_text(entry["summary"])}"
      else
        entry["type"].to_s
      end
    end

    def session_tree_visual_prefix(display_indent, gutters, show_connector, is_last, foldable)
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

    def session_tree_contains_active_path?(node, active_path)
      entry_id = (node[:source]["entry"] || {})["id"].to_s
      active_path.include?(entry_id) || node[:children].any? { |child| session_tree_contains_active_path?(child, active_path) }
    end

    def session_tree_active_path(roots, leaf_id)
      by_id = session_tree_entries_by_id(roots)
      ids = []
      entry = by_id[leaf_id.to_s]
      while entry
        ids << entry["id"].to_s
        entry = by_id[entry["parentId"].to_s]
      end
      ids
    end

    def session_tree_entries_by_id(roots)
      roots.each_with_object({}) do |root, map|
        stack = [root]
        until stack.empty?
          node = stack.pop
          entry = node["entry"] || {}
          map[entry["id"].to_s] = entry unless entry["id"].to_s.empty?
          stack.concat(Array(node["children"]))
        end
      end
    end

    def session_tree_tool_calls(roots)
      roots.each_with_object({}) do |root, tool_calls|
        stack = [root]
        until stack.empty?
          node = stack.pop
          entry = node["entry"] || {}
          message = entry["message"]
          if entry["type"] == "message" && message.is_a?(Hash) && message_role(message) == "assistant"
            message_tool_calls(message).each { |tool_call| tool_calls[tool_call_id(tool_call).to_s] = tool_call }
          end
          stack.concat(Array(node["children"]))
        end
      end
    end

    def session_tree_tool_display(message, tool_calls_by_id)
      tool_call = tool_calls_by_id[session_tree_message_tool_call_id(message).to_s]
      return session_tree_format_tool_call(tool_call) if tool_call

      name = session_tree_message_tool_name(message).to_s
      "[#{name.empty? ? 'tool' : name}]"
    end

    def session_tree_message_tool_call_id(message)
      message_tool_call_id(message)
    end

    def session_tree_message_tool_name(message)
      message_name(message)
    end

    def session_tree_format_tool_call(tool_call)
      name = ToolCall.display_name(tool_call)
      args = tool_call_args(tool_call)
      case name
      when "read"
        path = args["path"] || args[:path] || args["file_path"] || args[:file_path]
        offset = args["offset"] || args[:offset]
        limit = args["limit"] || args[:limit]
        display = path.to_s
        if offset || limit
          start_line = offset || 1
          end_line = limit ? start_line.to_i + limit.to_i - 1 : nil
          display += ":#{start_line}#{end_line ? "-#{end_line}" : ""}"
        end
        "[read: #{display}]"
      when "write", "edit"
        path = args["path"] || args[:path] || args["file_path"] || args[:file_path]
        "[#{name}: #{path}]"
      when "bash"
        command = (args["command"] || args[:command]).to_s.gsub(/[\n\t]/, " ").strip
        "[bash: #{command.length > 50 ? "#{command.slice(0, 50)}..." : command}]"
      else
        serialized = JSON.dump(args)
        "[#{name}: #{serialized.length > 40 ? "#{serialized.slice(0, 40)}..." : serialized}]"
      end
    end

    def display_message_text(message)
      truncate_session_tree_text(full_message_text(message))
    end

    def truncate_session_tree_text(text)
      normalized = text.to_s.gsub(/\s+/, " ").strip
      normalized.length > 120 ? "#{normalized.slice(0, 117)}..." : normalized
    end

    def full_message_text(message)
      MessageText.full_text(message)
    end

    def message_role(message)
      MessageAccess.role(message)
    end

    def message_content(message)
      MessageAccess.content(message)
    end

    def message_name(message)
      MessageAccess.name(message)
    end

    def message_tool_call_id(message)
      MessageAccess.tool_call_id(message)
    end

    def message_tool_calls(message)
      MessageAccess.tool_calls(message)
    end

    def tool_call_id(tool_call)
      ToolCall.id(tool_call)
    end

    def tool_call_args(tool_call)
      ToolCall.arguments(tool_call)
    end
  end
end

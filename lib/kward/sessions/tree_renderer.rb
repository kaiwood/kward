require_relative "../message_access"
require_relative "../message_text"
require_relative "tree_nodes"
require_relative "tree_tool_display"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Terminal renderer for persisted session tree choices.
  class SessionTreeRenderer
    def initialize(roots:, current_leaf_id:)
      @roots = roots
      @current_leaf_id = current_leaf_id
    end

    def items
      tree_nodes = SessionTreeNodes.new(roots: @roots, current_leaf: @current_leaf_id)
      tool_calls_by_id = tree_nodes.tool_calls

      tree_nodes.layout_rows.map do |row|
        prefix = row[:prefix].empty? ? "" : "      #{row[:prefix]}"
        {
          entry: row[:entry],
          label: session_tree_label(row[:entry], row[:source], prefix, row[:active_path], tool_calls_by_id)
        }
      end
    end

    private

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

    def session_tree_tool_display(message, tool_calls_by_id)
      tool_call = tool_calls_by_id[session_tree_message_tool_call_id(message).to_s]
      return SessionTreeToolDisplay.label(tool_call) if tool_call

      name = session_tree_message_tool_name(message).to_s
      "[#{name.empty? ? 'tool' : name}]"
    end

    def session_tree_message_tool_call_id(message)
      message_tool_call_id(message)
    end

    def session_tree_message_tool_name(message)
      message_name(message)
    end

    def display_message_text(message)
      SessionTreeNodes.truncate_text(full_message_text(message))
    end

    def truncate_session_tree_text(text)
      SessionTreeNodes.truncate_text(text)
    end

    def full_message_text(message)
      MessageText.full_text(message)
    end

    def message_role(message)
      MessageAccess.role(message)
    end

    def message_name(message)
      MessageAccess.name(message)
    end

    def message_tool_call_id(message)
      MessageAccess.tool_call_id(message)
    end

  end
end

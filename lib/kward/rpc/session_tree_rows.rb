require_relative "../message_access"
require_relative "../message_text"
require_relative "../session_tree_nodes"
require_relative "../session_tree_tool_display"

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
    # exact RPC payload shape.
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
        tree_nodes = SessionTreeNodes.new(roots: @roots, current_leaf: @current_leaf)
        tool_calls_by_id = tree_nodes.tool_calls

        tree_nodes.layout_rows.map do |row|
          entry = row[:entry]
          entry_id = entry["id"].to_s
          formatted = tree_entry_display(entry, tool_calls_by_id)
          {
            entryId: entry_id,
            parentId: entry["parentId"],
            role: formatted[:role],
            text: formatted[:text],
            current: !@current_leaf.to_s.empty? && entry_id == @current_leaf.to_s,
            depth: row[:depth],
            isLast: row[:is_last],
            ancestorContinues: row[:gutters].map { |gutter| gutter[:show] },
            activePath: row[:active_path],
            selectable: @selectable.call(entry),
            label: row[:source]["label"] || entry["resolvedLabel"],
            labelTimestamp: row[:source]["labelTimestamp"],
            prefix: row[:prefix]
          }.compact
        end
      end

      private

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

      def format_tool_result(message, tool_calls_by_id)
        tool_call = tool_calls_by_id[MessageAccess.tool_call_id(message).to_s]
        return SessionTreeToolDisplay.label(tool_call) if tool_call

        name = MessageAccess.tool_name(message).to_s
        name = "tool" if name.empty?
        "[#{name}]"
      end

      def display_message_text(message)
        MessageText.preview(message)
      end

      def truncate_tree_text(text)
        MessageText.truncate_preview(text)
      end
    end
  end
end

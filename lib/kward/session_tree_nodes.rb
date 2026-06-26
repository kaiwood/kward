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

    def contains_active_path?(node, active_path)
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

    def self.truncate_text(text)
      normalized = text.to_s.gsub(/\s+/, " ").strip
      normalized.length > 120 ? "#{normalized.slice(0, 117)}..." : normalized
    end

    private

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

require_relative "../message_access"

module Kward
  module RPC
    class SessionTree
      def initialize(rpc_session)
        @rpc_session = rpc_session
      end

      def entries
        @rpc_session.store.session_entries(@rpc_session.session.path)
      end

      def resolve_entry_id(entry_id, entries: self.entries)
        id = entry_id.to_s
        return id if entries.any? { |record| record["id"].to_s == id }

        match = id.match(/\Amessage:(\d+)\z/)
        return entries[match[1].to_i]&.dig("id") if match

        id
      end

      def active_path_ids(entries, leaf_id)
        by_id = entries.to_h { |entry| [entry["id"].to_s, entry] }
        ids = []
        current = by_id[leaf_id.to_s]
        while current
          ids << current["id"].to_s
          current = by_id[current["parentId"].to_s]
        end
        ids
      end

      def user_entry?(entry)
        message = entry["message"]
        message.is_a?(Hash) && MessageAccess.role(message) == "user"
      end

      def selectable_entry?(entry)
        !entry["id"].to_s.empty? && ["message", "compaction", "branch_summary"].include?(entry["type"])
      end
    end
  end
end

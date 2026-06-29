require_relative "../memory/manager"

# Namespace for the Kward CLI agent runtime.
module Kward
  # JSON-RPC backend namespace used by UI clients.
  module RPC
    # Memory-related RPC method implementations mixed into SessionManager.
    module MemoryMethods
      def memory_manager
        Memory::Manager.for_config_dir(@config_dir)
      end

      def memory_status
        manager = memory_manager
        { enabled: manager.enabled?, autoSummary: manager.auto_summary_enabled?, paths: manager.paths }
      end

      def memory_enable
        memory_manager.enable
        { enabled: true }
      end

      def memory_disable
        memory_manager.disable
        { enabled: false }
      end

      def memory_auto_summary_enable
        memory_manager.auto_summary_enable
        { autoSummary: true }
      end

      def memory_auto_summary_disable
        memory_manager.auto_summary_disable
        { autoSummary: false }
      end

      def memory_list(include_inactive: false, workspace_root: Dir.pwd)
        memory_manager.hierarchy(include_inactive: include_inactive, workspace_root: workspace_root)
      end

      def memory_add(text:, scope: nil, tags: [])
        { memory: memory_manager.add_soft(text, scope: scope || "global", tags: tags) }
      end

      def memory_add_core(text:, scope: nil, tags: [])
        { memory: memory_manager.add_core(text, scope: scope || "global", tags: tags) }
      end

      def memory_forget(id:)
        { forgotten: memory_manager.forget_memory(id) }
      end

      def memory_promote(id:)
        { memory: memory_manager.promote_memory(id) }
      end

      def memory_relax(id:, workspace_root: Dir.pwd)
        { memory: memory_manager.relax_core(id, workspace_root: workspace_root) }
      end

      def memory_inspect
        memory_manager.inspect_memory
      end

      def memory_why(session_id: nil)
        if session_id
          rpc_session = fetch_session(session_id)
          return rpc_session.conversation.last_memory_retrieval || memory_manager.explain_retrieval
        end

        memory_manager.explain_retrieval
      end

      def memory_summarize(session_id:)
        rpc_session = fetch_session(session_id)
        records = memory_manager.summarize_conversation(rpc_session.conversation, client: @client)
        persist_memory_state(rpc_session)
        { memories: records }
      end
    end
  end
end

require_relative "manager"

# Namespace for the Kward CLI agent runtime.
module Kward
  module Memory
    # Applies retrieved memory context to a conversation before a model turn.
    module TurnContext
      module_function

      def apply(conversation:, input:, manager: Manager.new)
        retrieval = manager.retrieve_relevant(input: input, workspace_root: conversation.workspace_root)
        conversation.last_memory_retrieval = retrieval
        conversation.memory_context = manager.memory_block(retrieval)
        conversation.refresh_system_message!
        retrieval
      end
    end
  end
end

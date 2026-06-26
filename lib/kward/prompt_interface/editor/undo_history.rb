# Namespace for the Kward CLI agent runtime.
module Kward
  # Interactive terminal UI used by the CLI frontend.
  class PromptInterface
    # Bounded undo/redo history for editor buffer snapshots.
    class EditorUndoHistory
      attr_reader :undo_stack, :redo_stack

      def initialize(limit: 100, undo_stack: [], redo_stack: [])
        @limit = limit
        @undo_stack = undo_stack
        @redo_stack = redo_stack
      end

      def push(snapshot)
        @undo_stack << snapshot
        trim(@undo_stack)
        @redo_stack.clear
      end

      def undo(current_snapshot)
        snapshot = @undo_stack.pop
        return nil unless snapshot

        @redo_stack << current_snapshot
        trim(@redo_stack)
        snapshot
      end

      def redo(current_snapshot)
        snapshot = @redo_stack.pop
        return nil unless snapshot

        @undo_stack << current_snapshot
        trim(@undo_stack)
        snapshot
      end

      private

      def trim(stack)
        stack.shift while stack.length > @limit
      end
    end
  end
end

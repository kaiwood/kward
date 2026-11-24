require_relative "buffer"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Interactive terminal UI used by the CLI frontend.
  class PromptInterface
    # Bounded undo/redo history for reversible edits and whole-buffer snapshots.
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

      def undo(&restore)
        transfer(@undo_stack, @redo_stack, &restore)
      end

      def redo(&restore)
        transfer(@redo_stack, @undo_stack, &restore)
      end

      def apply(entry, buffer)
        if (edits = entry[:edits])
          inverse = []
          apply_edits(edits, buffer) { |edit| inverse << edit }
          { edits: inverse.reverse.freeze }
        else
          previous = buffer.text.dup
          buffer.text = entry[:buffer].to_s
          { buffer: previous }
        end
      end

      # An untracked edit must not invalidate the deltas at either end of
      # history. Preserve the same targets that snapshots would have restored.
      def preserve_targets(text)
        [@undo_stack, @redo_stack].each do |stack|
          entry = stack.last
          next unless entry&.key?(:edits)

          buffer = EditorBuffer.new(text)
          apply_edits(entry[:edits], buffer)
          stack[-1] = entry.except(:edits).merge(buffer: buffer.text)
        end
      end

      private

      def apply_edits(edits, buffer, &capture)
        edits.each do |offset, length, replacement|
          buffer.replace_range(offset, offset + length, replacement, &capture)
        end
      end

      def transfer(from, to)
        entry = from.last
        return false unless entry

        inverse = yield entry
        from.pop
        to << inverse
        trim(to)
        true
      end

      def trim(stack)
        stack.shift while stack.length > @limit
      end
    end
  end
end

# Namespace for the Kward CLI agent runtime.
module Kward
  # Interactive terminal UI used by the CLI frontend.
  class PromptInterface
    # Current-buffer word completion for the built-in composer file editor.
    module EditorWordCompletion
      EDITOR_COMPLETION_WORD_PATTERN = /[[:alnum:]_]+/.freeze
      EDITOR_COMPLETION_PREFIX_PATTERN = /[[:alnum:]_]+\z/.freeze
      EDITOR_COMPLETION_SUFFIX_PATTERN = /\A[[:alnum:]_]*/.freeze

      private

      def editor_complete_buffer_word
        if (cycle = matching_editor_completion_cycle)
          return cycle_editor_word_completion(cycle) if cycle[:candidates].length > 1

          reset_editor_word_completion
        end

        context = editor_word_completion_context
        return false unless context

        candidates = editor_word_completion_candidates(context)
        return false if candidates.empty?

        @editor_word_completion = context.merge(
          editor_state: @editor_state,
          candidates: candidates,
          index: 0,
          previous_status: @editor_state.status
        )
        apply_editor_word_completion(@editor_word_completion)
        true
      end

      def editor_word_completion_context
        buffer = @editor_state.buffer
        cursor = @editor_state.cursor
        prefix_match = buffer[0...cursor].to_s.match(EDITOR_COMPLETION_PREFIX_PATTERN)
        return nil unless prefix_match

        suffix = buffer[cursor..].to_s.match(EDITOR_COMPLETION_SUFFIX_PATTERN).to_s
        {
          prefix: prefix_match[0],
          range_start: prefix_match.begin(0),
          range_end: cursor + suffix.length
        }
      end

      def editor_word_completion_candidates(context)
        matches = []
        @editor_state.buffer.to_enum(:scan, EDITOR_COMPLETION_WORD_PATTERN).each do
          match = Regexp.last_match
          next if editor_completion_match_overlaps_context?(match, context)

          word = match[0]
          next unless word.length > context[:prefix].length
          next unless word.start_with?(context[:prefix])

          matches << [word, match.begin(0)]
        end

        matches
          .sort_by { |_word, offset| editor_completion_candidate_order(offset, context) }
          .map(&:first)
          .uniq
      end

      def editor_completion_match_overlaps_context?(match, context)
        match.begin(0) < context[:range_end] && match.end(0) > context[:range_start]
      end

      def editor_completion_candidate_order(offset, context)
        if offset < context[:range_start]
          [0, context[:range_start] - offset]
        else
          [1, offset - context[:range_end]]
        end
      end

      def matching_editor_completion_cycle
        cycle = @editor_word_completion
        return nil unless cycle

        same_editor = cycle[:editor_state].equal?(@editor_state)
        same_buffer = cycle[:buffer] == @editor_state.buffer
        same_cursor = cycle[:cursor] == @editor_state.cursor
        return cycle if same_editor && same_buffer && same_cursor

        reset_editor_word_completion
        nil
      end

      def cycle_editor_word_completion(cycle)
        cycle[:index] = (cycle[:index] + 1) % cycle[:candidates].length
        apply_editor_word_completion(cycle)
        true
      end

      def apply_editor_word_completion(cycle)
        candidate = cycle[:candidates][cycle[:index]]
        @editor_state.replace_range(cycle[:range_start], cycle[:range_end], candidate)
        @editor_state.cursor = cycle[:range_start] + candidate.length
        cycle[:range_end] = @editor_state.cursor
        cycle[:buffer] = @editor_state.buffer
        cycle[:cursor] = @editor_state.cursor
        cycle[:status] = "Completion #{cycle[:index] + 1}/#{cycle[:candidates].length}: #{candidate}"
        @editor_state.status = cycle[:status]
      end

      def reset_editor_word_completion
        cycle = @editor_word_completion
        if cycle && cycle[:editor_state].status == cycle[:status]
          cycle[:editor_state].status = cycle[:previous_status]
        end
        @editor_word_completion = nil
      end

      def editor_word_completion_tab_key?(key)
        !editor_tab_sequence_for(key).nil?
      end
    end
  end
end

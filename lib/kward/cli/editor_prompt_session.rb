# Namespace for the Kward CLI agent runtime.
module Kward
  # Transactional draft used while an agent works on an active editor buffer.
  #
  # The live terminal editor remains owned by PromptInterface. Agent tool calls
  # update this draft and the caller commits it only after a successful turn.
  class EditorPromptSession
    class InvalidEdit < StandardError; end

    attr_reader :context, :content

    def initialize(context)
      @context = context.dup
      @initial_content = @context.fetch(:content).to_s.dup.freeze
      @content = @initial_content
      @targets = edit_targets
      @draft_proposed = false
    end

    def replace(content)
      raise InvalidEdit, "clear the selection before replacing the whole buffer" if Array(@context[:selections]).any?
      ensure_new_draft!
      raise InvalidEdit, "content must be a string" unless content.is_a?(String)

      @content = content.dup.freeze
      @draft_proposed = true
    end

    def edit(edits)
      ensure_new_draft!
      raise InvalidEdit, "provide at least one edit" unless edits.is_a?(Array) && !edits.empty?

      seen = {}
      replacements = edits.map do |entry|
        raise InvalidEdit, "each edit needs a target and replacement text" unless entry.is_a?(Hash)

        target = entry[:target] || entry["target"]
        text = entry[:content] || entry["content"]
        range = @targets[target]
        raise InvalidEdit, "target is unavailable in this snapshot" unless range
        raise InvalidEdit, "duplicate target" if seen[target]
        raise InvalidEdit, "content must be a string" unless text.is_a?(String)

        seen[target] = true
        [*range, text]
      end

      cursor = 0
      length = @initial_content.length
      draft = String.new(encoding: @initial_content.encoding)
      replacements.sort_by { |first, last, _| [first, last] }.each do |first, last, text|
        raise InvalidEdit, "targets overlap or are out of bounds" unless cursor <= first && first <= last && last <= length

        draft << @initial_content[cursor...first] << text
        cursor = last
      end
      @content = (draft << @initial_content[cursor..]).freeze
      @draft_proposed = true
    end

    def changed?
      @content != @initial_content
    end

    def initial_content
      @initial_content
    end

    private

    def ensure_new_draft!
      raise InvalidEdit, "submit all edits together in one draft" if @draft_proposed
    end

    def edit_targets
      selections = Array(@context[:selections])
      if selections.any?
        return selections.each_with_index.to_h do |selection, index|
          ["selection:#{index + 1}", selection.values_at(:start_offset, :end_offset)]
        end
      end

      targets = {}
      offset = @context[:cursor_offset]
      targets["cursor"] = [offset, offset] if offset
      targets["current_line"] = @context[:cursor_line_range] if @context[:cursor_line_range]
      targets
    end
  end
end

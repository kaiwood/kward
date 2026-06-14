module Kward
  class PromptInterface
    class ComposerState
      attr_accessor :input, :cursor, :kill_buffer, :history_index, :history_draft, :prefill_input
      attr_reader :attachments, :history

      def initialize
        @input = +""
        @cursor = 0
        @attachments = []
        @kill_buffer = ""
        @history = []
        @history_index = nil
        @history_draft = nil
        @prefill_input = nil
      end
    end
  end
end

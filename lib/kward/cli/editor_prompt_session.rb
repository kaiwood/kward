# Namespace for the Kward CLI agent runtime.
module Kward
  # Transactional draft used while an agent works on an active editor buffer.
  #
  # The live terminal editor remains owned by PromptInterface. Agent tool calls
  # update this draft and the caller commits it only after a successful turn.
  class EditorPromptSession
    attr_reader :context, :content

    def initialize(context)
      @context = context.dup
      @initial_content = @context.fetch(:content).to_s.dup
      @content = @initial_content.dup
    end

    def replace(content)
      @content = content.to_s
    end

    def changed?
      @content != @initial_content
    end

    def initial_content
      @initial_content.dup
    end
  end
end

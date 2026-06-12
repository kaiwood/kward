module Kward
  module ContextOverflow
    OVERFLOW_PATTERNS = [
      /prompt is too long/i,
      /request_too_large/i,
      /input is too long for requested model/i,
      /exceeds the context window/i,
      /exceeds (?:the )?(?:model'?s )?maximum context length of [\d,]+ tokens?/i,
      /input token count.*exceeds the maximum/i,
      /maximum prompt length is \d+/i,
      /reduce the length of the messages/i,
      /maximum context length is \d+ tokens/i,
      /exceeds (?:the )?maximum allowed input length of [\d,]+ tokens?/i,
      /input \(\d+ tokens\) is longer than the model'?s context length \(\d+ tokens\)/i,
      /exceeds the limit of \d+/i,
      /exceeds the available context size/i,
      /greater than the context length/i,
      /context window exceeds limit/i,
      /exceeded model token limit/i,
      /too large for model with \d+ maximum context length/i,
      /model_context_window_exceeded/i,
      /prompt too long; exceeded (?:max )?context length/i,
      /context[_ ]length[_ ]exceeded/i,
      /too many tokens/i,
      /token limit exceeded/i
    ].freeze

    NON_OVERFLOW_PATTERNS = [
      /^(Throttling error|Service unavailable):/i,
      /rate limit/i,
      /too many requests/i
    ].freeze

    module_function

    def error?(error)
      text = error_text(error)
      return false if text.empty?
      return false if NON_OVERFLOW_PATTERNS.any? { |pattern| text.match?(pattern) }
      return true if request_too_large?(error)

      OVERFLOW_PATTERNS.any? { |pattern| text.match?(pattern) }
    end

    def error_text(error)
      parts = [error.message]
      parts << error.body if error.respond_to?(:body)
      parts.compact.join("\n")
    end

    def request_too_large?(error)
      error.respond_to?(:code) && error.code.to_i == 413
    end
  end
end

module Kward
  module Events
    ReasoningDelta = Struct.new(:delta, keyword_init: true)
    AssistantDelta = Struct.new(:delta, keyword_init: true)
    AssistantMessage = Struct.new(:message, keyword_init: true)
    ToolCall = Struct.new(:tool_call, keyword_init: true)
    ToolResult = Struct.new(:tool_call, :content, keyword_init: true)
    Answer = Struct.new(:content, keyword_init: true)
  end
end

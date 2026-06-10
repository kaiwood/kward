module Kward
  module Events
    ReasoningDelta = Struct.new(:delta, keyword_init: true)
    AssistantDelta = Struct.new(:delta, keyword_init: true)
    AssistantMessage = Struct.new(:message, keyword_init: true)
    Retry = Struct.new(:provider, :model, :attempt, :max_attempts, :delay_seconds, :error, :request_bytes, keyword_init: true)
    Steering = Struct.new(:input, :created_at, keyword_init: true)
    SteeringApplied = Struct.new(:count, keyword_init: true)
    ToolCall = Struct.new(:tool_call, keyword_init: true)
    ToolResult = Struct.new(:tool_call, :content, keyword_init: true)
    Answer = Struct.new(:content, keyword_init: true)
  end
end

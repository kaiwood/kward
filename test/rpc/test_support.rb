require_relative "../test_helper"
require_relative "../../lib/kward/rpc/server"
require_relative "../../lib/kward/rpc/session_manager"
require_relative "../../lib/kward/rpc/transport"

module KwardRPCTestSupport
  def framed(message)
    body = JSON.generate(message)
    "Content-Length: #{body.bytesize}\r\n\r\n#{body}"
  end

  def read_framed_messages(output)
    input = StringIO.new(output.string)
    messages = []
    loop do
      message = Kward::RPC::Transport.new(input: input, output: StringIO.new).read_message
      break unless message

      messages << message
    end
    messages
  end

  def run_rpc(messages, client: KwardTestCase::FakeClient.new([]), env: {}, experimental_workers: false)
    input = StringIO.new(messages.map { |message| framed(message) }.join)
    output = StringIO.new
    with_env(env) do
      Kward::RPC::Server.new(input: input, output: output, error_output: StringIO.new, client: client, experimental_workers: experimental_workers).run
    end
    read_framed_messages(output)
  end

  def wait_until(timeout: 2, message: "timed out", &block)
    super(timeout: timeout, message: message, &block)
  end

  class StaticContextUsage
    def initialize(tokens:)
      @tokens = tokens
    end

    def call(provider:, model:, context_window:, context_parts:)
      {
        tokens: @tokens,
        contextWindow: context_window,
        percent: ((@tokens.to_f / context_window.to_i) * 100).round(2)
      }
    end
  end

  class RecordingServer
    attr_reader :notifications

    def initialize
      @notifications = []
    end

    def notify(method, params = {})
      @notifications << { method: method, params: params }
    end

    def error_payload(error)
      { code: error.class.name, message: error.message }
    end

    def log_error(error)
      raise error
    end
  end

  class SlowClient
    def chat(_messages, tools: [], on_assistant_delta: nil)
      sleep 0.1
      on_assistant_delta&.call("slow")
      { "role" => "assistant", "content" => "slow" }
    end
  end

  class SteeringClient
    def supports_in_flight_steer?
      true
    end

    def chat(_messages, tools: [], on_assistant_delta: nil, steering: nil)
      on_assistant_delta&.call("before")
      steering.wait(timeout: 1)
      on_assistant_delta&.call("after")
      { "role" => "assistant", "content" => "beforeafter" }
    end
  end

  class BlockingCancellableClient
    def initialize
      @mutex = Mutex.new
      @condition = ConditionVariable.new
      @cancelled = false
    end

    def chat(_messages, tools: [], cancellation: nil, on_reasoning_delta: nil, on_assistant_delta: nil)
      cancellation&.on_cancel do
        @mutex.synchronize do
          @cancelled = true
          @condition.broadcast
        end
      end
      @mutex.synchronize do
        @condition.wait(@mutex) until @cancelled
      end
      cancellation&.raise_if_cancelled!
      on_assistant_delta&.call("late")
      { "role" => "assistant", "content" => "late" }
    end

    def cancelled?
      @mutex.synchronize { @cancelled }
    end
  end

  class RetryEventClient
    def chat(_messages, tools: [], on_reasoning_delta: nil, on_retry: nil, on_assistant_delta: nil, cancellation: nil)
      on_retry&.call(provider: "Codex", model: "fake-model", attempt: 2, max_attempts: 3, delay_seconds: 1, error: "Codex request failed: 503 upstream")
      on_assistant_delta&.call("answer")
      { "role" => "assistant", "content" => "answer" }
    end
  end

  class ReasoningStreamingClient
    def chat(_messages, tools: [], on_reasoning_delta: nil, on_reasoning_boundary: nil, on_assistant_delta: nil)
      on_reasoning_delta&.call("because")
      on_reasoning_boundary&.call
      on_assistant_delta&.call("answer")
      { "role" => "assistant", "content" => "answer" }
    end
  end

  class ErrorClient
    def chat(_messages, tools: [])
      raise "boom"
    end
  end

  class ToolRecordingClient < KwardTestCase::FakeClient
    attr_reader :seen_tools

    def initialize
      super([])
      @seen_tools = []
    end

    def chat(_messages, tools: [], **_opts)
      @seen_tools << tools
      { "role" => "assistant", "content" => "ok" }
    end
  end

  class FakeMCPClient
    attr_reader :name, :calls

    def initialize(name: "safari-mcp-stp", tools: nil)
      @name = name
      @tools = tools || [
        {
          "name" => "inspect.page",
          "description" => "Inspect the active page",
          "inputSchema" => {
            "type" => "object",
            "properties" => { "selector" => { "type" => "string" } },
            "required" => ["selector"],
            "additionalProperties" => false
          }
        }
      ]
      @calls = []
    end

    def list_tools
      @tools
    end

    def call_tool(name, arguments)
      @calls << [name, arguments]
      { "content" => [{ "type" => "text", "text" => "DOM looks good" }] }
    end
  end

  class ReloadableFakeClient < KwardTestCase::FakeClient
    attr_reader :reload_count

    def initialize(responses, config_path)
      super(responses)
      @config_path = config_path
      @reload_count = 0
    end

    def current_provider
      case config["provider"]
      when "copilot" then "Copilot"
      when "openrouter" then "OpenRouter"
      else super
      end
    end

    def current_model
      case current_provider
      when "Copilot"
        config["copilot_model"] || super
      when "OpenRouter"
        config["openrouter_model"] || super
      else
        config["openai_model"] || super
      end
    end

    def current_reasoning_effort
      case current_provider
      when "Copilot"
        config["copilot_reasoning_effort"] || super
      when "OpenRouter"
        config["openrouter_reasoning_effort"] || super
      else
        config["openai_reasoning_effort"] || super
      end
    end

    def reload_config
      @reload_count += 1
    end

    private

    def config
      return {} unless File.exist?(@config_path)

      JSON.parse(File.read(@config_path))
    end
  end
end

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

  def run_rpc(messages, client: KwardTestCase::FakeClient.new([]), env: {})
    input = StringIO.new(messages.map { |message| framed(message) }.join)
    output = StringIO.new
    with_env(env) do
      Kward::RPC::Server.new(input: input, output: output, error_output: StringIO.new, client: client).run
    end
    read_framed_messages(output)
  end

  def wait_until(timeout: 2)
    deadline = Time.now + timeout
    until yield
      raise "timed out" if Time.now > deadline

      sleep 0.01
    end
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
    def chat(_messages, tools: [], on_reasoning_delta: nil, on_assistant_delta: nil)
      on_reasoning_delta&.call("because")
      on_assistant_delta&.call("answer")
      { "role" => "assistant", "content" => "answer" }
    end
  end

  class ErrorClient
    def chat(_messages, tools: [])
      raise "boom"
    end
  end

  class ReloadableFakeClient < KwardTestCase::FakeClient
    attr_reader :reload_count

    def initialize(responses, config_path)
      super(responses)
      @config_path = config_path
      @reload_count = 0
    end

    def current_model
      config["openai_model"] || super
    end

    def current_reasoning_effort
      config["openai_reasoning_effort"] || super
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

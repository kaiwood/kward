require_relative "test_helper"

class TestTypeSafe < KwardTestCase
  FakeClient = Struct.new(:response, :available) do
    def available?
      available
    end

    def evaluate(**_arguments)
      response
    end
  end

  def test_typesafe_tool_is_only_advertised_when_configured
    absent = Kward::ToolRegistry.new(typesafe_client: FakeClient.new({}, false))
    refute_includes tool_names(absent), "typesafe_evaluate"

    configured = Kward::ToolRegistry.new(typesafe_client: FakeClient.new({}, true))
    assert_includes tool_names(configured), "typesafe_evaluate"
  end

  def test_typesafe_tool_returns_structured_answers
    response = {
      "model" => "jev-1.13.0",
      "answers" => { "urgent" => { "type" => "noul", "noul" => 0.98 } },
      "usage" => { "input_tokens" => 12, "output_tokens" => 2 }
    }
    registry = Kward::ToolRegistry.new(typesafe_client: FakeClient.new(response, true))

    result = registry.dispatch(
      tool_call("typesafe_evaluate", {
        "state" => "The customer needs help today.",
        "questions" => {
          "urgent" => { "type" => "noul", "instructions" => "Is this urgent?" }
        }
      }),
      Kward::Conversation.new(system_message: nil)
    )

    assert_includes result, '"noul": 0.98'
    assert_includes result, '"input_tokens": 12'
  end

  def test_typesafe_tool_rejects_invalid_questions_before_request
    client = FakeClient.new({}, true)
    registry = Kward::ToolRegistry.new(typesafe_client: client)

    result = registry.dispatch(
      tool_call("typesafe_evaluate", { "state" => "text", "questions" => { "bad" => { "type" => "unknown" } } }),
      Kward::Conversation.new(system_message: nil)
    )

    assert_equal "Error: question \"bad\" has unsupported type", result
  end

  def test_typesafe_client_sends_bearer_request_and_parses_response
    response = Struct.new(:body) do
      def is_a?(klass)
        klass == Net::HTTPSuccess || super
      end
    end.new(JSON.dump("model" => "jev-1.13.0", "answers" => {}))
    connection = Class.new do
      attr_reader :request

      define_method(:request) do |request = nil|
        return @request if request.nil?

        @request = request
        response
      end
    end.new
    http = Class.new do
      define_method(:start) do |_host, _port, **_options, &block|
        block.call(connection)
      end
    end.new

    client = Kward::TypeSafeClient.new(api_key: "secret", http: http)
    result = client.evaluate(state: "text", questions: { "ok" => { "type" => "noul", "instructions" => "Is it okay?" } })

    assert_equal "jev-1.13.0", result.fetch("model")
    assert_equal "Bearer secret", connection.request["Authorization"]
    assert_equal "jev-latest", JSON.parse(connection.request.body).fetch("model")
  end

  private

  def tool_names(registry)
    registry.schemas.map { |schema| schema[:function][:name] }
  end
end

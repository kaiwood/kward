require_relative "test_helper"

class TestCrewReporter < KwardTestCase
  class CrewClient
    attr_reader :calls
    attr_accessor :provider, :model, :reasoning_effort

    def initialize(responses)
      @responses = responses
      @calls = []
      @provider = "Codex"
      @model = "gpt-main"
      @reasoning_effort = "high"
    end

    def chat(messages, tools: [], model: nil, reasoning: nil)
      @calls << { messages: messages, model: model, reasoning: reasoning }
      content = @responses.shift
      content.is_a?(Hash) ? content : { "role" => "assistant", "content" => content }
    end

    def current_provider
      @provider
    end

    def current_model
      @model
    end

    def current_reasoning_effort
      @reasoning_effort
    end
  end

  def test_report_queries_active_non_reasoning_personas_as_system_context_and_summarizes
    Dir.mktmpdir do |workspace|
      config = {
        "personas" => {
          "default" => "Default persona.",
          "workspaces" => { workspace => "Workspace persona." },
          "models" => { "gpt-main" => "Model persona." },
          "persona_modifiers" => {
            "reasoning" => { "high" => "Reasoning persona should be ignored." },
            "suffix" => "Suffix persona."
          }
        }
      }
      client = CrewClient.new(["default identity", "workspace identity", "model identity", "suffix identity", "## Crew\n- Report"])

      report = Kward::CrewReporter.new(
        client: client,
        workspace_root: workspace,
        model: "gpt-main",
        reasoning_effort: "high",
        config: config
      ).report

      assert report.success?
      assert_equal "## Crew\n- Report", report.summary
      assert_equal 5, client.calls.length
      assert_equal ["Default persona.", "Workspace persona.", "Model persona.", "Suffix persona."], client.calls[0, 4].map { |call| call[:messages].first[:content] }
      refute client.calls[0, 4].any? { |call| call[:messages].first[:content].include?("Reasoning persona") }
      assert_equal [false, false, false, false, false], client.calls.map { |call| call[:reasoning] }
      assert_equal ["gpt-main", "gpt-main", "gpt-main", "gpt-main", "gpt-main"], client.calls.map { |call| call[:model] }
      assert_includes client.calls.last[:messages].last[:content], "default identity"
    end
  end

  def test_model_persona_uses_its_associated_model
    config = { "personas" => { "models" => { "gpt-alt" => "Alternate model persona." } } }
    client = CrewClient.new(["alt identity", "summary"])

    report = Kward::CrewReporter.new(
      client: client,
      workspace_root: Dir.pwd,
      model: "gpt-alt",
      reasoning_effort: "medium",
      config: config
    ).report

    assert report.success?
    assert_equal "gpt-alt", client.calls.first[:model]
  end

  def test_unsupported_provider_and_empty_personas_do_not_call_model
    client = CrewClient.new([])
    client.provider = "OpenRouter"

    unsupported = Kward::CrewReporter.new(client: client, workspace_root: Dir.pwd, model: "gpt-main", reasoning_effort: "medium", config: {}).report

    assert_equal :unsupported, unsupported.status
    assert_includes unsupported.message, "OpenAI OAuth"
    assert_empty client.calls

    client.provider = "Codex"
    empty = Kward::CrewReporter.new(client: client, workspace_root: Dir.pwd, model: "gpt-main", reasoning_effort: "medium", config: {}).report

    assert_equal :empty, empty.status
    assert_includes empty.message, "No active personas"
    assert_empty client.calls
  end
end

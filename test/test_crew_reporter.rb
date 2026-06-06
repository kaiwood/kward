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

  def test_report_queries_crew_personas_without_modifiers_and_formats_table
    Dir.mktmpdir do |workspace|
      config = {
        "personas" => {
          "default" => "Default persona.",
          "workspaces" => { workspace => "Workspace persona." },
          "models" => {
            "gpt-alt" => "Alternate model persona.",
            "gpt-main" => "Model persona."
          },
          "persona_modifiers" => {
            "reasoning" => { "high" => "Reasoning persona should be ignored." },
            "time_of_day" => { "morning" => "Time persona should be ignored." },
            "weekday" => { "saturday" => "Weekday persona should be ignored." },
            "suffix" => "Suffix persona should be ignored."
          }
        }
      }
      client = CrewClient.new(["default identity", "workspace identity", "alt identity", "model identity"])

      report = Kward::CrewReporter.new(
        client: client,
        workspace_root: workspace,
        model: "gpt-main",
        reasoning_effort: "high",
        config: config,
        now: Time.new(2024, 6, 1, 8, 0, 0)
      ).report

      assert report.success?
      assert_includes report.summary, "Crew Summary"
      assert_equal 4, client.calls.length
      queried_prompts = client.calls[0, 4].map { |call| call[:messages].first[:content] }
      assert_equal ["Default persona.", "Workspace persona.", "Alternate model persona.", "Model persona."], queried_prompts
      refute queried_prompts.any? { |prompt| prompt.include?("should be ignored") }
      assert_equal [false, false, false, false], client.calls.map { |call| call[:reasoning] }
      assert_equal ["gpt-main", "gpt-main", "gpt-alt", "gpt-main"], client.calls.map { |call| call[:model] }
      assert_includes report.summary, "| Persona"
      assert_includes report.summary, "| Model"
      assert_includes report.summary, "| Identity"
      assert_includes report.summary, "| default"
      refute_includes report.summary, "default [model:"
      assert_includes report.summary, "| workspace (#{workspace})"
      assert_includes report.summary, "| model (gpt-alt)"
      assert_includes report.summary, "| model (gpt-main)"
    end
  end

  def test_summary_uses_aligned_table
    config = {
      "personas" => {
        "default" => "Default persona.",
        "models" => { "gpt-alt" => "Alternate model persona." }
      }
    }
    client = CrewClient.new(["default identity", "alternate identity"])

    report = Kward::CrewReporter.new(
      client: client,
      workspace_root: Dir.pwd,
      model: "gpt-main",
      reasoning_effort: "medium",
      config: config
    ).report

    assert report.success?
    assert_includes report.summary, "| Persona         | Model   | Identity           |"
    assert_includes report.summary, "| --------------- | ------- | ------------------ |"
    assert_includes report.summary, "| default         |         | default identity   |"
    assert_includes report.summary, "| model (gpt-alt) | gpt-alt | alternate identity |"
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

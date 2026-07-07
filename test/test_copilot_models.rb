require_relative "test_helper"

class TestCopilotModels < KwardTestCase
  def test_parses_catalog_shapes_and_filters_disabled_entries
    body = JSON.dump(
      "data" => [
        { "id" => "gpt-5-mini" },
        { "model" => "gemini-2.5-pro" },
        { "name" => "hidden", "model_picker_enabled" => false },
        "oswe-agent"
      ]
    )

    assert_equal ["gpt-5-mini", "gemini-2.5-pro", "oswe-agent"], Kward::CopilotModels.parse(body)
  end

  def test_returns_empty_list_for_invalid_catalog_json
    assert_equal [], Kward::CopilotModels.parse("not json")
  end

  def test_recognizes_supported_model_families
    assert Kward::CopilotModels.supported?("gpt-5-mini")
    assert Kward::CopilotModels.supported?("gpt-5.1")
    assert Kward::CopilotModels.supported?("gemini-2.5-pro")
    assert Kward::CopilotModels.supported?("gpt-4.1")
    assert Kward::CopilotModels.supported?("oswe-agent")
    refute Kward::CopilotModels.supported?("claude-sonnet")
  end
end

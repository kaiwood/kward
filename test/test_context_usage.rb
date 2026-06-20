require_relative "test_helper"
require_relative "../lib/kward/model/context_usage"

class TestContextUsage < KwardTestCase
  class CountingTokenCounter
    attr_reader :texts, :models

    def initialize
      @texts = []
      @models = []
    end

    def count(text, model:)
      @texts << text
      @models << model
      text.scan(/[A-Za-z0-9_]+/).length
    end
  end

  def test_omits_usage_until_session_content_exists
    usage = Kward::ContextUsage.new(token_counter: CountingTokenCounter.new).call(
      provider: "Codex",
      model: "gpt-5",
      context_window: 400_000,
      context_parts: {
        instructions: "Be concise",
        input: [],
        tools: [{ type: "function", name: "read_file", description: "Read files" }]
      }
    )

    assert_nil usage
  end

  def test_counts_serialized_openai_context_parts
    token_counter = CountingTokenCounter.new
    usage = Kward::ContextUsage.new(token_counter: token_counter).call(
      provider: "Codex",
      model: "gpt-5",
      context_window: 400_000,
      context_parts: {
        instructions: "Be concise",
        input: [{ type: "message", role: "user", content: [{ type: "input_text", text: "hello world" }] }],
        tools: [{ type: "function", name: "read_file", description: "Read files" }]
      }
    )

    assert usage[:tokens] > 0
    assert_equal 400_000, usage[:contextWindow]
    assert_equal ((usage[:tokens].to_f / 400_000) * 100).round(2), usage[:percent]
    assert_equal true, usage[:estimated]
    assert_equal ["gpt-5"], token_counter.models
    assert_includes token_counter.texts.first, "Be concise"
    assert_includes token_counter.texts.first, "read_file"
  end

  def test_redacts_image_data_from_usage_estimate
    token_counter = CountingTokenCounter.new
    usage = Kward::ContextUsage.new(token_counter: token_counter).call(
      provider: "Codex",
      model: "gpt-5",
      context_window: 400_000,
      context_parts: {
        instructions: "Be concise",
        input: [{ type: "message", role: "user", content: [{ type: "input_image", image_url: "data:image/png;base64,abc" }] }],
        tools: []
      }
    )

    assert usage[:tokens] > 0
    assert_includes token_counter.texts.first, "[image omitted from token estimate]"
    refute_includes token_counter.texts.first, "data:image/png;base64,abc"
  end

  def test_counts_usage_for_any_provider_with_a_context_window
    usage = Kward::ContextUsage.new(token_counter: CountingTokenCounter.new).call(
      provider: "OpenRouter",
      model: "z-ai/glm-5.2",
      context_window: 128_000,
      context_parts: { messages: [{ role: "user", content: "hello" }], tools: [] }
    )

    assert usage[:tokens] > 0
    assert_equal 128_000, usage[:contextWindow]
    assert_equal true, usage[:estimated]
  end

  def test_tiktoken_counter_falls_back_when_model_encoding_is_unknown
    counter = Kward::TiktokenTokenCounter.new
    counter.define_singleton_method(:encoding) { |_model| nil }

    assert_operator counter.count("hello world", model: "z-ai/glm-5.2"), :>, 0
  end
end

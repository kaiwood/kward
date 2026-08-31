require_relative "test_helper"
require_relative "../lib/kward/transcripts/markdown_transcript"

class TestMarkdownTranscript < KwardTestCase
  def test_renders_display_content_and_skips_system_message
    conversation = Kward::Conversation.new(system_message: nil)
    conversation.messages << { role: "system", content: "hidden" }
    conversation.append_user("Expanded prompt", display_content: "/plan fix")
    conversation.append_assistant("planned")

    markdown = Kward::MarkdownTranscript.new(conversation).render

    assert_includes markdown, "# Kward Session"
    assert_includes markdown, "/plan fix"
    assert_includes markdown, "planned"
    refute_includes markdown, "hidden"
    refute_includes markdown, "Expanded prompt"
  end

  def test_renders_image_parts_with_rpc_and_cli_mime_keys
    conversation = Kward::Conversation.new(
      system_message: nil,
      messages: [
        { role: "user", content: [{ type: "image", path: "rpc.png", mimeType: "image/png" }] },
        { role: "assistant", content: [{ type: "image", path: "cli.webp", media_type: "image/webp" }] }
      ]
    )

    markdown = Kward::MarkdownTranscript.new(conversation).render

    assert_includes markdown, "[image/png: rpc.png]"
    assert_includes markdown, "[image/webp: cli.webp]"
  end

  def test_renders_reasoning_parts_without_mislabeling_them_as_images
    conversation = Kward::Conversation.new(
      system_message: nil,
      messages: [
        {
          role: "assistant",
          content: [
            { type: "thinking", thinking: "checked the route" },
            { type: "text", text: "answer" }
          ]
        }
      ]
    )

    markdown = Kward::MarkdownTranscript.new(conversation).render

    assert_includes markdown, "Reasoning:\nchecked the route"
    assert_includes markdown, "answer"
    refute_includes markdown, "[image]"
  end

  def test_skips_unknown_parts_without_text
    conversation = Kward::Conversation.new(
      system_message: nil,
      messages: [
        { role: "assistant", content: [{ type: "unknown", data: "ignored" }, { type: "text", text: "answer" }] }
      ]
    )

    markdown = Kward::MarkdownTranscript.new(conversation).render

    assert_includes markdown, "answer"
    refute_includes markdown, "ignored"
    refute_includes markdown, "[image]"
  end
end

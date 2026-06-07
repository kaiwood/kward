require_relative "test_helper"
require_relative "../lib/kward/markdown_transcript"

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
end

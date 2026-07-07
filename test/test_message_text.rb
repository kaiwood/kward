require_relative "test_helper"
require_relative "../lib/kward/message_text"

class TestMessageText < KwardTestCase
  def test_preview_prefers_display_content_and_normalizes_whitespace
    message = {
      role: "user",
      content: "Expanded\nprivate prompt",
      display_content: " /plan   fix\n bug "
    }

    assert_equal "/plan fix bug", Kward::MessageText.preview(message)
  end

  def test_preview_uses_compaction_summary
    message = { role: "compactionSummary", content: "hidden", summary: " summarized\ncontext " }

    assert_equal "summarized context", Kward::MessageText.preview(message)
  end

  def test_preview_truncates_with_ellipsis
    message = { role: "assistant", content: "a" * 130 }

    assert_equal "#{"a" * 117}...", Kward::MessageText.preview(message)
  end
end

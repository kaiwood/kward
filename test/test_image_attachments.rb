require_relative "test_helper"

class TestImageAttachments < KwardTestCase
  def test_terminal_image_sequence_renders_inline_image_escape
    part = { type: "image", media_type: "image/png", data: Base64.strict_encode64("png bytes"), path: "/tmp/pasted.png" }

    sequence = Kward::ImageAttachments.terminal_image_sequence(part, env: {})

    assert_equal "\e_Ginline=1;preserveAspectRatio=1;width=40;name=#{Base64.strict_encode64("pasted.png")}:#{Base64.strict_encode64("png bytes")}\e\\", sequence
  end

  def test_terminal_image_sequence_uses_iterm_protocol_in_iterm
    part = { type: "image", media_type: "image/png", data: Base64.strict_encode64("png bytes"), path: "/tmp/pasted.png" }

    sequence = Kward::ImageAttachments.terminal_image_sequence(part, env: { "TERM_PROGRAM" => "iTerm.app" })

    assert_equal "\e]1337;File=inline=1;preserveAspectRatio=1;width=40;name=#{Base64.strict_encode64("pasted.png")}:#{Base64.strict_encode64("png bytes")}\a", sequence
  end

end

require_relative "test_helper"

class TestConversation < KwardTestCase
  def test_conversation_attaches_pasted_image_path
    path = "kward_image_attach.png"
    File.binwrite(path, "png bytes")
    conversation = Kward::Conversation.new(system_message: nil)

    conversation.append_user("look at #{path}")

    content = conversation.messages.last[:content]
    assert_equal "look at #{path}", content.first[:text]
    assert_equal "image/png", content[1][:media_type]
    assert_equal Base64.strict_encode64("png bytes"), content[1][:data]
  ensure
    File.delete(path) if path && File.exist?(path)
  end

end

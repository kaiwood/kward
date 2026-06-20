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

  def test_append_tool_normalizes_binary_encoded_content_to_utf_8
    binary_content = +"caf\xc3\xa9 r\xc3\xa9sum\xc3\xa9"
    binary_content = binary_content.force_encoding(Encoding::ASCII_8BIT)
    conversation = Kward::Conversation.new(system_message: nil)

    conversation.append_tool(tool_call_id: "call_1", name: "fetch_content", content: binary_content)

    stored = conversation.messages.last[:content]
    assert_equal Encoding::UTF_8, stored.encoding
    assert stored.valid_encoding?
  end

  def test_append_tool_scrubs_invalid_binary_bytes
    invalid_binary = +"caf\xe9\xff\xfe"
    invalid_binary = invalid_binary.force_encoding(Encoding::ASCII_8BIT)
    conversation = Kward::Conversation.new(system_message: nil)

    conversation.append_tool(tool_call_id: "call_2", name: "fetch_raw", content: invalid_binary)

    stored = conversation.messages.last[:content]
    assert_equal Encoding::UTF_8, stored.encoding
    assert stored.valid_encoding?
  end

  def test_append_tool_preserves_utf_8_content
    utf8_content = +"caf\xc3\xa9"
    utf8_content = utf8_content.force_encoding(Encoding::UTF_8)
    conversation = Kward::Conversation.new(system_message: nil)

    conversation.append_tool(tool_call_id: "call_3", name: "read_file", content: utf8_content)

    assert_equal Encoding::UTF_8, conversation.messages.last[:content].encoding
  end

  def test_default_system_prompt_is_stable_across_time_bucket_changes
    first = Kward::Conversation.new.system_message[:content]
    second = Kward::Conversation.new.system_message[:content]

    assert_equal first, second
  end

  def test_compact_preserves_system_message_and_resets_read_paths
    compacted = nil
    conversation = Kward::Conversation.new(system_message: { role: "system", content: "system" }, read_paths: ["README.md"])
    conversation.on_compact = lambda { |message| compacted = message }
    conversation.append_user("hello")
    conversation.append_assistant("reply")

    conversation.compact!("summary")

    assert_equal({ role: "system", content: "system" }, conversation.system_message)
    assert_equal [{ role: "assistant", content: "summary" }], conversation.messages
    assert_equal [
      { role: "system", content: "system" },
      { role: "assistant", content: "summary" }
    ], conversation.context_messages
    assert_empty conversation.read_paths
    assert_equal({ role: "assistant", content: "summary" }, compacted)
  end

end

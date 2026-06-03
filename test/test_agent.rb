require_relative "test_helper"

class TestAgent < KwardTestCase
  def test_agent_allows_claim_after_successful_edit_file
    path = "kward_agent_edit.txt"
    File.write(path, "old\n")
    client = FakeClient.new([
      assistant_tool_call("read_file", path: path),
      assistant_tool_call("edit_file", path: path, edits: [{ old_text: "old", new_text: "new" }]),
      { "role" => "assistant", "content" => "I edited the file." }
    ])
    agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new)

    answer = agent.ask("edit it")

    assert_equal "I edited the file.", answer
    assert_equal "new\n", File.read(path)
  ensure
    File.delete(path) if path && File.exist?(path)
  end

end

require_relative "test_helper"

class TestOpenEditorTool < KwardTestCase
  class EditorPrompt
    attr_reader :opened_paths

    def initialize(result: true)
      @result = result
      @opened_paths = []
    end

    def edit_file(path, base_dir:, allow_new:)
      @opened_paths << { path: path, base_dir: base_dir, allow_new: allow_new }
      @result
    end
  end

  def test_registry_advertises_open_editor_only_with_editor_support
    without_editor = Kward::ToolRegistry.new(web_search_enabled: false, mcp_clients: []).schemas.map { |schema| schema[:function][:name] }
    with_editor = Kward::ToolRegistry.new(prompt: EditorPrompt.new, web_search_enabled: false, mcp_clients: []).schemas.map { |schema| schema[:function][:name] }

    refute_includes without_editor, "open_editor"
    assert_includes with_editor, "open_editor"
    assert_equal "open_editor", Kward::ToolCall.normalized_name("open_editor")
  end

  def test_open_editor_opens_an_existing_workspace_file
    Dir.mktmpdir do |dir|
      path = File.join(dir, "notes.md")
      File.write(path, "Notes\n")
      prompt = EditorPrompt.new
      registry = Kward::ToolRegistry.new(
        workspace: Kward::Workspace.new(root: dir),
        prompt: prompt,
        web_search_enabled: false,
        mcp_clients: []
      )
      conversation = Kward::Conversation.new(system_message: nil, workspace_root: dir)

      result = registry.dispatch(tool_call("open_editor", path: "notes.md"), conversation)

      assert_equal "Opened notes.md in the integrated editor.", result
      assert_equal [{ path: File.realpath(path), base_dir: Pathname.new(dir).realpath, allow_new: false }], prompt.opened_paths
    end
  end

  def test_open_editor_rejects_paths_outside_the_workspace
    Dir.mktmpdir do |dir|
      prompt = EditorPrompt.new
      registry = Kward::ToolRegistry.new(
        workspace: Kward::Workspace.new(root: dir),
        prompt: prompt,
        web_search_enabled: false,
        mcp_clients: []
      )
      conversation = Kward::Conversation.new(system_message: nil, workspace_root: dir)

      result = registry.dispatch(tool_call("open_editor", path: "../outside.txt"), conversation)

      assert_match(/Error: could not open \.\.\/outside\.txt: path outside workspace/, result)
      assert_empty prompt.opened_paths
    end
  end
end

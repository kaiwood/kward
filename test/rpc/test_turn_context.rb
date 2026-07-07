require_relative "../test_helper"

class TestRPCTurnContext < KwardTestCase
  def test_normalizes_and_renders_client_context
    context = Kward::RPC::TurnContext.normalize(
      activeFile: "lib/example.rb",
      openFiles: ["README.md", ""],
      selection: { path: "lib/example.rb", startLine: "2", endLine: "4", text: "puts :hi" },
      diagnostics: [{ path: "lib/example.rb", line: "3", severity: "error", message: "undefined method" }]
    )

    assert_equal "lib/example.rb", context[:active_file]
    assert_equal ["README.md"], context[:open_files]
    assert_equal({ path: "lib/example.rb", start_line: 2, end_line: 4, text: "puts :hi" }, context[:selection])
    assert_equal [{ path: "lib/example.rb", line: 3, severity: "error", message: "undefined method" }], context[:diagnostics]

    prompt = Kward::RPC::TurnContext.prompt(context)
    assert_includes prompt, "Additional client context:"
    assert_includes prompt, "- Active file: lib/example.rb"
    assert_includes prompt, "- Open files: README.md"
    assert_includes prompt, "- Selection: lib/example.rb:2-4"
    assert_includes prompt, "puts :hi"
    assert_includes prompt, "- Diagnostic: error lib/example.rb:3 undefined method"
  end

  def test_rejects_invalid_context_shapes
    assert_raises(ArgumentError) { Kward::RPC::TurnContext.normalize("nope") }
    assert_raises(ArgumentError) { Kward::RPC::TurnContext.normalize(selection: "nope") }
    assert_raises(ArgumentError) { Kward::RPC::TurnContext.normalize(diagnostics: "nope") }
    assert_raises(ArgumentError) { Kward::RPC::TurnContext.normalize(openFiles: "nope") }
  end
end

require_relative "test_helper"

class TestPluginUI < KwardTestCase
  def test_structured_requests_are_normalized_and_return_frontend_answers
    requests = []
    answers = {
      question: [{ question: "Continue?", answer: "Yes" }],
      select: "deploy",
      confirm: true,
      input: "release-42"
    }
    backend = Kward::PluginUI::Backend.new(
      capabilities: { question: true, select: true, confirm: true, input: true },
      requester: lambda do |kind, payload, cancellation: nil|
        requests << [kind, payload, cancellation]
        answers.fetch(kind)
      end
    )
    ui = Kward::PluginUI.new(backend: backend)

    question = question_args("Continue?")
    assert_equal answers[:question], ui.question([question])
    assert_equal "deploy", ui.select("Action", [{ label: "Deploy", value: "deploy", description: "Ship it." }])
    assert_equal true, ui.confirm("Release", "Continue?")
    assert_equal "release-42", ui.input("Release name", "For example, release-42")

    assert_equal %i[question select confirm input], requests.map(&:first)
    assert requests.all? { |_kind, payload, _cancellation| payload.frozen? }
  end

  def test_unsupported_requests_fail_closed_and_events_fall_back_to_text
    output = []
    ui = Kward::PluginUI.new(say_callback: ->(message) { output << message })

    assert_nil ui.question([question_args("Continue?")])
    assert_nil ui.select("Action", ["Deploy"])
    assert_equal false, ui.confirm("Continue?")
    assert_nil ui.input("Release name")
    ui.notify("Done", :success)
    ui.progress(id: "sync", message: "Synchronizing", percent: 50)

    assert_equal ["Done", "Synchronizing (50%)"], output
    refute ui.supported?(:select)
  end

  def test_events_are_structured_for_supported_frontends
    events = []
    backend = Kward::PluginUI::Backend.new(
      capabilities: { notify: true, progress: true },
      emitter: ->(kind, payload) { events << [kind, payload] }
    )
    ui = Kward::PluginUI.new(backend: backend)

    ui.notify("Finished", level: :success)
    ui.progress("download", "Downloading", percent: 12.5, done: false)

    assert_equal :notify, events[0][0]
    assert_equal({ message: "Finished", level: :success }, events[0][1])
    assert_equal :progress, events[1][0]
    assert_equal({ id: "download", message: "Downloading", percent: 12.5, done: false }, events[1][1])
  end

  def test_blocking_requests_preserve_cooperative_cancellation
    cancellation = Kward::Cancellation.new
    backend = Kward::PluginUI::Backend.new(
      capabilities: { input: true },
      requester: lambda do |_kind, _payload, cancellation:|
        cancellation.cancel!
        "ignored"
      end
    )
    ui = Kward::PluginUI.new(backend: backend, cancellation: cancellation)

    assert_raises(Kward::Cancellation::CancelledError) { ui.input("Name") }
  end

  def test_select_rejects_invalid_options_and_unknown_frontend_answers
    backend = Kward::PluginUI::Backend.new(
      capabilities: { select: true },
      requester: ->(*) { "missing" }
    )
    ui = Kward::PluginUI.new(backend: backend)

    assert_raises(ArgumentError) { ui.select("Action", []) }
    assert_raises(ArgumentError) { ui.select("Action", ["Same", "Same"]) }
    error = assert_raises(ArgumentError) { ui.select("Action", ["Deploy"]) }
    assert_equal "plugin UI returned an unknown selection", error.message
  end

  def test_rejects_invalid_frontend_input_and_unbounded_event_data
    backend = Kward::PluginUI::Backend.new(
      capabilities: { input: true },
      requester: ->(*) { { unexpected: true } }
    )
    ui = Kward::PluginUI.new(backend: backend)

    assert_raises(ArgumentError) { ui.input("Name") }
    assert_raises(ArgumentError) { ui.progress(id: "", message: "Working") }
    assert_raises(ArgumentError) { ui.progress(id: "work", message: "Working", percent: 101) }
    assert_raises(ArgumentError) { ui.notify("Done", level: :debug) }
  end

  def test_context_exposes_ui_and_scopes_cancellation_for_tools
    cancellation = Kward::Cancellation.new
    tool_ui = Kward::PluginUI.new(
      backend: Kward::PluginUI::Backend.new(capabilities: { select: true }, requester: ->(*) { "Deploy" })
    )
    context = Kward::PluginRegistry::Context.new(
      conversation: Kward::Conversation.new,
      tool_ui: tool_ui
    )
    tool_context = context.for_tool(conversation: Kward::Conversation.new, cancellation: cancellation)

    assert_instance_of Kward::PluginUI, context.ui
    refute context.ui.supported?(:select)
    assert tool_context.ui.supported?(:select)
    assert_same cancellation, tool_context.cancellation
  end
end

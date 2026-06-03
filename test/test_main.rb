require "minitest/autorun"
require "stringio"
require_relative "../lib/main"
require_relative "../lib/kward/ansi"
require_relative "../lib/kward/client"
require_relative "../lib/kward/cli"
require_relative "../lib/kward/prompt_interface"
require_relative "../lib/kward/tool_registry"
require_relative "../lib/kward/workspace"

class TestMain < Minitest::Test
  def test_client_requires_openai_oauth_login_or_openrouter
    client = Kward::Client.new(api_key: nil, openai_access_token: nil, oauth: FakeOAuth.new(nil))

    error = assert_raises(RuntimeError) do
      client.chat([{ role: "user", content: "hello" }])
    end

    assert_equal Kward::Client::AUTH_ERROR, error.message
  end

  def test_openai_oauth_default_auth_path_constructs
    assert_includes Kward::OpenAIOAuth.new.auth_path, ".kward/auth.json"
  end

  def test_openai_oauth_requires_external_config_file_for_client_id
    oauth = Kward::OpenAIOAuth.new(auth_path: "tmp_auth.json", config_path: "missing_kward_config.json")

    error = assert_raises(RuntimeError) do
      oauth.authorization_url(redirect_uri: "http://localhost:1455/auth/callback", code_challenge: "challenge", state: "state-123")
    end

    assert_equal "Kward config not found: #{File.expand_path("missing_kward_config.json")}", error.message
  end

  def test_openai_oauth_authorization_url_includes_configured_client_id_pkce_and_state
    path = "kward_test_config.json"
    File.write(path, JSON.dump("openai_oauth_client_id" => "configured-client"))
    oauth = Kward::OpenAIOAuth.new(auth_path: "tmp_auth.json", config_path: path)
    url = URI.parse(oauth.authorization_url(
      redirect_uri: "http://localhost:1455/auth/callback",
      code_challenge: "challenge",
      state: "state-123"
    ))
    params = URI.decode_www_form(url.query).to_h

    assert_equal "https", url.scheme
    assert_equal "auth.openai.com", url.host
    assert_equal "code", params["response_type"]
    assert_equal "configured-client", params["client_id"]
    assert_equal "challenge", params["code_challenge"]
    assert_equal "S256", params["code_challenge_method"]
    assert_equal "state-123", params["state"]
  ensure
    File.delete(path) if path && File.exist?(path)
  end

  def test_openai_oauth_save_auth_is_readable_by_client_and_private
    path = "kward_test_auth.json"
    oauth = Kward::OpenAIOAuth.new(auth_path: path)

    oauth.save_auth(tokens: { "access_token" => "oauth-access", "refresh_token" => "refresh", "expires_in" => 3600 })

    assert_equal "oauth-access", oauth.access_token
    assert_equal 0o600, File.stat(path).mode & 0o777
  ensure
    File.delete(path) if path && File.exist?(path)
  end

  def test_openai_oauth_rejects_state_mismatch
    oauth = Kward::OpenAIOAuth.new(auth_path: "tmp_auth.json")

    assert_raises(RuntimeError) do
      oauth.authorization_code_from("http://localhost:1455/auth/callback?code=abc&state=wrong", expected_state: "right")
    end
  end

  def test_codex_oauth_defaults_to_gpt_5_5_medium_reasoning
    client = Kward::Client.new(api_key: nil, openai_access_token: "token", oauth: FakeOAuth.new(nil))

    payload = client.send(:codex_payload, [{ role: "user", content: "hello" }], [])

    assert_equal "gpt-5.5", payload[:model]
    assert_equal({ effort: "medium", summary: "auto" }, payload[:reasoning])
    assert_equal true, payload[:stream]
    assert_equal false, payload[:store]
  end

  def test_codex_oauth_reads_model_and_reasoning_from_config
    path = "kward_test_config.json"
    File.write(path, JSON.dump("openai_model" => "gpt-config", "openai_reasoning_effort" => "high"))
    client = Kward::Client.new(api_key: nil, openai_access_token: "token", oauth: FakeOAuth.new(nil), config_path: path)

    payload = client.send(:codex_payload, [{ role: "user", content: "hello" }], [])

    assert_equal "gpt-config", payload[:model]
    assert_equal({ effort: "high", summary: "auto" }, payload[:reasoning])
  ensure
    File.delete(path) if path && File.exist?(path)
  end

  def test_config_model_and_thinking_level_apply_to_current_provider
    path = "kward_test_config.json"
    File.write(path, JSON.dump("model" => "configured-model", "thinking_level" => "low"))
    client = Kward::Client.new(api_key: nil, openai_access_token: "token", oauth: FakeOAuth.new(nil), config_path: path)

    payload = client.send(:codex_payload, [{ role: "user", content: "hello" }], [])

    assert_equal "configured-model", payload[:model]
    assert_equal({ effort: "low", summary: "auto" }, payload[:reasoning])
  ensure
    File.delete(path) if path && File.exist?(path)
  end

  def test_openrouter_reads_model_from_config
    path = "kward_test_config.json"
    File.write(path, JSON.dump("openrouter_model" => "provider/configured"))
    client = Kward::Client.new(api_key: "token", openai_access_token: nil, oauth: FakeOAuth.new(nil), config_path: path)

    payload = client.send(:request_payload, "OpenRouter", [{ role: "user", content: "hello" }], [])

    assert_equal "provider/configured", payload[:model]
  ensure
    File.delete(path) if path && File.exist?(path)
  end

  def test_openrouter_defaults_to_openai_gpt_5_5
    client = Kward::Client.new(api_key: "token", openai_access_token: nil, oauth: FakeOAuth.new(nil))

    payload = client.send(:request_payload, "OpenRouter", [{ role: "user", content: "hello" }], [])

    assert_equal "openai/gpt-5.5", payload[:model]
    refute payload.key?(:reasoning_effort)
  end

  def test_openai_oauth_takes_precedence_over_openrouter_env
    client = Kward::Client.new(api_key: "openrouter-token", openai_access_token: nil, oauth: FakeOAuth.new("oauth-token"))

    url, token, provider = client.send(:credentials)

    assert_equal Kward::Client::CODEX_URL, url
    assert_equal "oauth-token", token
    assert_equal "Codex", provider
  end

  def test_openrouter_is_fallback_when_no_openai_oauth_exists
    client = Kward::Client.new(api_key: "openrouter-token", openai_access_token: nil, oauth: FakeOAuth.new(nil))

    url, token, provider = client.send(:credentials)

    assert_equal Kward::Client::OPENROUTER_URL, url
    assert_equal "openrouter-token", token
    assert_equal "OpenRouter", provider
  end

  def test_openai_access_token_takes_precedence_over_saved_oauth
    client = Kward::Client.new(api_key: nil, openai_access_token: "env-token", oauth: FakeOAuth.new("oauth-token"))

    _url, token, provider = client.send(:credentials)

    assert_equal "env-token", token
    assert_equal "Codex", provider
  end

  def test_codex_sse_parses_text_response
    client = Kward::Client.new(api_key: nil, openai_access_token: "env-token", oauth: FakeOAuth.new(nil))
    body = "data: {\"type\":\"response.output_text.delta\",\"delta\":\"hi\"}\n\n" \
      "data: {\"type\":\"response.completed\",\"response\":{}}\n\n"

    message = client.send(:parse_codex_sse, body)

    assert_equal "assistant", message["role"]
    assert_equal "hi", message["content"]
  end

  def test_codex_sse_parses_reasoning_summary
    client = Kward::Client.new(api_key: nil, openai_access_token: "env-token", oauth: FakeOAuth.new(nil))
    deltas = []
    body = "data: {\"type\":\"response.reasoning_summary_text.delta\",\"delta\":\"thinking\"}\n\n" \
      "data: {\"type\":\"response.output_text.delta\",\"delta\":\"hi\"}\n\n"

    message = client.send(:parse_codex_sse, body, on_reasoning_delta: ->(delta) { deltas << delta })

    assert_equal "thinking", message["reasoning_summary"]
    assert_equal ["thinking"], deltas
  end

  def test_codex_sse_parses_tool_call
    client = Kward::Client.new(api_key: nil, openai_access_token: "env-token", oauth: FakeOAuth.new(nil))
    event = {
      "type" => "response.output_item.done",
      "item" => {
        "type" => "function_call",
        "call_id" => "call_1",
        "name" => "list_directory",
        "arguments" => JSON.dump("path" => ".")
      }
    }
    body = "data: #{JSON.dump(event)}\n\n"

    message = client.send(:parse_codex_sse, body)

    assert_equal "call_1", message["tool_calls"].first["id"]
    assert_equal "list_directory", message["tool_calls"].first["function"]["name"]
  end

  def test_ansi_colorizes_when_enabled_and_strips_sequences
    colored = Kward::ANSI.colorize("Assistant>", :green, :bold, enabled: true)

    assert_equal "\e[32;1mAssistant>\e[0m", colored
    assert_equal "Assistant>", Kward::ANSI.strip(colored)
    assert_equal "Assistant>", Kward::ANSI.colorize("Assistant>", :green, enabled: false)
  end

  def test_ansi_enablement_respects_environment_overrides
    output = FakeInput.new("", tty: false)

    assert Kward::ANSI.enabled?(output, env: { "KWARD_COLOR" => "always" })
    refute Kward::ANSI.enabled?(output, env: { "KWARD_COLOR" => "never" })
    refute Kward::ANSI.enabled?(FakeInput.new("", tty: true), env: { "NO_COLOR" => "1" })
    assert Kward::ANSI.enabled?(output, env: { "FORCE_COLOR" => "1" })
  end

  def test_cli_colors_stream_labels_when_forced
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), client: FakeClient.new([]))
    cli.instance_variable_set(:@color_enabled, true)
    output = capture_io do
      cli.send(:start_stream_block, "Assistant")
    end.first

    assert_includes output, "\e[32;1mAssistant>\e[0m"
  end

  def test_module_split_keeps_one_shot_mode_working
    cli = Kward::CLI.new(argv: ["hello"], stdin: FakeInput.new("", tty: true), client: FakeClient.new([{ "role" => "assistant", "content" => "hi" }]))

    assert_equal "hi", cli.one_shot("hello")
  end

  def test_interactive_conversation_history_still_works
    prompt = FakePrompt.new(["hello", "again", "/exit"])
    client = RecordingClient.new(["reply 1", "reply 2"])
    agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new(prompt: prompt))
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)

    conversation = cli.interactive_loop(agent: agent)

    assert_equal "hello", client.seen_messages[0][1][:content]
    assert_equal "reply 1", client.seen_messages[1][2]["content"]
    assert_equal "again", client.seen_messages[1][3][:content]
    assert_equal 5, conversation.messages.length
  end

  def test_interactive_loop_exits_when_prompt_returns_nil
    prompt = FakePrompt.new([nil])
    client = RecordingClient.new([])
    agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new(prompt: prompt))
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)

    conversation = cli.interactive_loop(agent: agent)

    assert_empty client.seen_messages
    assert_empty conversation.messages
  end

  def test_prompt_interface_renders_empty_composer_before_typing
    output = StringIO.new
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: output)

    prompt.start

    refute_includes output.string, "You> "
  end

  def test_prompt_interface_renders_boxed_composer_and_scroll_region
    output = StringIO.new
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: output)

    prompt.start

    assert_includes output.string, "╭ You "
    refute_includes output.string, "│ You> "
    assert_includes output.string, "╰"
    assert_match(/\e\[1;\d+r/, output.string)
    refute_includes output.string, TTY::Cursor.clear_screen
  end

  def test_prompt_interface_enables_and_restores_keyboard_protocol
    output = StringIO.new
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: output)

    prompt.start
    prompt.close

    assert_includes output.string, "\e[>1u"
    assert_includes output.string, "\e[r"
    assert_includes output.string, "\e[<u"
  end

  def test_prompt_interface_renders_output_when_screen_has_extra_rows
    output = StringIO.new
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: output)
    prompt.start
    output.truncate(0)
    output.rewind

    prompt.say("first\nsecond")

    assert_includes output.string, "first"
    assert_includes output.string, "second"
  end

  def test_prompt_interface_submits_input_on_enter
    input, writer = IO.pipe
    output = StringIO.new
    writer.write("hello\r")
    writer.close
    prompt = Kward::PromptInterface.new(input: input, output: output)

    assert_equal "hello", prompt.ask("You>")
  ensure
    input&.close unless input&.closed?
  end

  def test_prompt_interface_exits_on_ctrl_d_when_empty
    assert_nil ask_prompt_with_input("\x04")
  end

  def test_prompt_interface_exits_on_csi_u_ctrl_d_when_empty
    assert_nil ask_prompt_with_input("\e[4u")
    assert_nil ask_prompt_with_input("\e[100;5u")
  end

  def test_prompt_interface_does_not_exit_on_ctrl_d_when_text_remains
    assert_equal "hello", ask_prompt_with_input("hello\x04\r")
  end

  def test_prompt_interface_handles_cursor_movement_keys
    input, writer = IO.pipe
    output = StringIO.new
    writer.write("ab\e[DZ\r")
    writer.close
    prompt = Kward::PromptInterface.new(input: input, output: output)

    assert_equal "aZb", prompt.ask("You>")
  ensure
    input&.close unless input&.closed?
  end

  def test_prompt_interface_backspace_deletes_empty_line
    input, writer = IO.pipe
    output = StringIO.new
    writer.write("hello\e[13;2u\b\r")
    writer.close
    prompt = Kward::PromptInterface.new(input: input, output: output)

    assert_equal "hello", prompt.ask("You>")
  ensure
    input&.close unless input&.closed?
  end

  def test_prompt_interface_backspace_after_escape_return_shift_enter_deletes_empty_line
    input, writer = IO.pipe
    output = StringIO.new
    writer.write("hello\e\r\x7F\r")
    writer.close
    prompt = Kward::PromptInterface.new(input: input, output: output)

    assert_equal "hello", prompt.ask("You>")
  ensure
    input&.close unless input&.closed?
  end

  def test_prompt_interface_inserts_newline_on_shift_enter_variants
    ["\e[13;2u", "\e[13;2~", "\e[27;2;13~", "\e\r", "\e\n"].each do |sequence|
      assert_equal "hello\nworld", ask_prompt_with_input("hello#{sequence}world\r")
    end
  end

  def test_prompt_interface_pastes_bracketed_multiline_text
    assert_equal "hello\nworld", ask_prompt_with_input("\e[200~hello\nworld\e[201~\r")
  end

  def test_prompt_interface_reuses_history_with_up_arrow
    input, writer = IO.pipe
    output = StringIO.new
    writer.write("first\r\e[A\r")
    writer.close
    prompt = Kward::PromptInterface.new(input: input, output: output)

    assert_equal "first", prompt.ask("You>")
    assert_equal "first", prompt.ask("You>")
  ensure
    input&.close unless input&.closed?
  end

  def test_prompt_interface_queues_input_while_busy
    input, writer = IO.pipe
    output = StringIO.new
    writer.write("next\r")
    writer.close
    prompt = Kward::PromptInterface.new(input: input, output: output)
    prompt.begin_busy_input("You>")

    queued = poll_prompt_until(prompt) { |result| result.is_a?(String) }

    assert_equal "next", queued
    refute_includes output.string, "You> "
  ensure
    input&.close unless input&.closed?
  end

  def test_prompt_interface_does_not_redraw_composer_between_stream_chunks
    output = StringIO.new
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: output)
    prompt.begin_busy_input("You>")
    output.truncate(0)
    output.rewind

    prompt.start_stream_block("Assistant")
    prompt.write_delta("hello")

    assert_includes output.string, "Assistant>"
    assert_includes output.string, "hello"
    refute_includes strip_ansi(output.string), Kward::PromptInterface::HELP_TEXT
    refute_includes strip_ansi(output.string), Kward::PromptInterface::BUSY_HELP_TEXT
    refute_includes strip_ansi(output.string), "You> "
    refute_includes strip_ansi(output.string), "╭"
  end

  def test_prompt_interface_writes_transcript_newlines_as_crlf
    output = StringIO.new
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: output)
    prompt.begin_busy_input("You>")
    output.truncate(0)
    output.rewind

    prompt.start_stream_block("Tool output")
    prompt.write_delta(".git/\n.gitignore\nREADME.md\n")

    stripped = strip_ansi(output.string)
    assert_includes stripped, "Tool output>\r\n.git/\r\n.gitignore\r\nREADME.md\r\n"
  end

  def test_prompt_interface_caps_boxed_composer_height
    prompt = Kward::PromptInterface.new(input: StringIO.new, output: StringIO.new)
    value = (1..10).map { |index| "line #{index}" }.join("\n")
    prompt.instance_variable_set(:@input, value)
    prompt.instance_variable_set(:@cursor, value.length)

    rows, cursor_row, = prompt.send(:composer_layout, 80)

    assert_operator rows.length, :<=, Kward::PromptInterface::COMPOSER_MAX_INPUT_ROWS + 2
    assert_operator cursor_row, :<, rows.length - 1
    assert_includes rows.join("\n"), "line 10"
  end

  def test_prompt_interface_submits_on_csi_u_enter
    assert_equal "hello", ask_prompt_with_input("hello\e[13u")
  end

  def test_prompt_interface_csi_u_backspace_deletes_empty_line
    assert_equal "hello", ask_prompt_with_input("hello\e[13;2u\e[127u\r")
  end

  def test_prompt_interface_handles_bundled_csi_u_keys
    assert_equal "hello", ask_prompt_with_input("hello\e[13;2u\e[127u\e[13u")
  end

  def test_prompt_interface_wraps_before_terminal_width
    input, writer = IO.pipe
    output = StringIO.new
    writer.write("abcde\r")
    writer.close
    prompt = Kward::PromptInterface.new(input: input, output: output)

    prompt.instance_variable_set(:@input, "abcde")
    assert prompt.send(:input_rows, 10).all? { |row| row.length < 10 }

    original_width = TTY::Screen.method(:width)
    TTY::Screen.define_singleton_method(:width) { 10 }

    assert_equal "abcde", prompt.ask("You>")
  ensure
    TTY::Screen.define_singleton_method(:width, original_width) if original_width
    input&.close unless input&.closed?
  end

  def test_interactive_turn_returns_prompt_queued_during_streaming
    input, writer = IO.pipe
    output = StringIO.new
    prompt = Kward::PromptInterface.new(input: input, output: output)
    client = StreamingRecordingClient.new(["reply 1"])
    agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new(prompt: prompt))
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)

    writer_thread = Thread.new do
      sleep 0.03
      writer.write("second\r")
      writer.close
    end

    queued = cli.send(:run_interactive_turn, agent, "first")

    assert_equal ["second"], queued
    assert_equal "first", client.seen_messages[0][1][:content]
  ensure
    writer_thread&.join
    input&.close unless input&.closed?
  end

  def test_status_slash_command_prints_static_status_without_calling_client
    prompt = FakePrompt.new(["/status", "/exit"])
    client = RecordingClient.new([])
    agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new(prompt: prompt))
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)

    cli.interactive_loop(agent: agent)

    assert_includes prompt.output.join("\n"), Kward::CLI::STATUS_MESSAGE
    assert_empty client.seen_messages
  end

  def test_tool_schemas_include_edit_file_shell_command_and_web_research
    tool_names = Kward::ToolRegistry.new.schemas.map { |schema| schema[:function][:name] }

    assert_equal ["list_directory", "read_file", "write_file", "edit_file", "run_shell_command", "web_research"], tool_names
  end

  def test_web_research_uses_duckduckgo_results
    html = '<div class="result"><a class="result__a" href="https://example.com/ruby">Ruby News</a><a class="result__snippet">Ruby release notes</a></div>'
    http = FakeHttpClient.new(
      ["POST", "https://html.duckduckgo.com/html/"] => fake_response(200, html)
    )
    research = Kward::WebResearch.new(http_client: http, searxng_instances: [])

    result = research.search("queries" => ["ruby news"])

    assert_includes result, "# Web research"
    assert_includes result, "Provider: duckduckgo"
    assert_includes result, "Ruby News"
    assert_includes result, "https://example.com/ruby"
  end

  def test_web_research_falls_back_to_searxng_json
    http = FakeHttpClient.new(
      ["POST", "https://html.duckduckgo.com/html/"] => fake_response(429, "rate limited"),
      ["GET", "https://searx.test/search?q=ruby&format=json"] => fake_response(200, JSON.dump(
        "results" => [{ "title" => "Fallback Result", "url" => "https://example.com/fallback", "content" => "search snippet" }]
      ))
    )
    research = Kward::WebResearch.new(http_client: http, searxng_instances: ["https://searx.test"])

    result = research.search("queries" => ["ruby"])

    assert_includes result, "Provider fallback note: DuckDuckGo search failed with HTTP 429"
    assert_includes result, "Provider: searxng"
    assert_includes result, "search snippet"
  end

  def test_web_research_uses_searxng_html_when_json_is_disabled
    html = '<article class="result"><h3><a href="https://example.com/html-page">HTML Result</a></h3><p class="content">HTML snippet</p></article>'
    http = FakeHttpClient.new(
      ["POST", "https://html.duckduckgo.com/html/"] => fake_response(500, "nope"),
      ["GET", "https://searx.test/search?q=ruby&format=json"] => fake_response(403, "json disabled"),
      ["GET", "https://searx.test/search?q=ruby"] => fake_response(200, html)
    )
    research = Kward::WebResearch.new(http_client: http, searxng_instances: ["https://searx.test"])

    result = research.search("queries" => ["ruby"])

    assert_includes result, "HTML Result"
    assert_includes result, "HTML snippet"
  end

  def test_web_research_returns_clear_error_when_all_providers_fail
    http = FakeHttpClient.new(
      ["POST", "https://html.duckduckgo.com/html/"] => fake_response(500, "nope"),
      ["GET", "https://searx.test/search?q=ruby&format=json"] => fake_response(403, "json disabled")
    )
    research = Kward::WebResearch.new(http_client: http, searxng_instances: ["https://searx.test"])

    result = research.search("queries" => ["ruby"])

    assert_includes result, "Error: web_research found no results"
    assert_includes result, "DuckDuckGo search failed with HTTP 500"
    assert_includes result, "SearXNG search failed with HTTP 403"
  end

  def test_web_research_truncates_large_output
    html = "<div class=\"result\"><a class=\"result__a\" href=\"https://example.com/large\">Large</a><a class=\"result__snippet\">#{"x" * 500}</a></div>"
    http = FakeHttpClient.new(
      ["POST", "https://html.duckduckgo.com/html/"] => fake_response(200, html)
    )
    research = Kward::WebResearch.new(http_client: http, searxng_instances: [], max_output_bytes: 120)

    result = research.search("queries" => ["ruby"])

    assert_includes result, "... truncated to 120 bytes"
  end

  def test_tool_registry_dispatches_web_research
    research = FakeWebResearch.new("research result")
    registry = Kward::ToolRegistry.new(web_research: research)
    conversation = Kward::Conversation.new

    result = registry.dispatch(tool_call("web_research", queries: ["ruby"]), conversation)

    assert_equal "research result", result
    assert_equal [{ "queries" => ["ruby"] }], research.calls
  end

  def test_list_directory_and_read_file_still_work
    workspace = Kward::Workspace.new

    assert_includes workspace.list_directory("."), "README.md"
    assert_includes workspace.read_file("README.md"), "# Ruby CLI Agent"
  end

  def test_outside_workspace_reads_and_writes_are_rejected
    workspace = Kward::Workspace.new

    assert_match(/Error: path outside workspace:/, workspace.read_file("../Gemfile"))
    assert_match(/Error: path outside workspace:/, workspace.write_file("../outside.txt", "nope", read_paths: []))
    assert_match(/Error: path outside workspace:/, workspace.edit_file("../Gemfile", [{ "old_text" => "x", "new_text" => "y" }], read_paths: []))
  end

  def test_reject_oversized_file
    path = "oversized_test_file.tmp"
    File.write(path, "x" * (Kward::Workspace::MAX_FILE_BYTES + 1))

    assert_match(/Error: file too large:/, Kward::Workspace.new.read_file(path))
  ensure
    File.delete(path) if path && File.exist?(path)
  end

  def test_existing_file_write_requires_prior_successful_read
    path = "kward_existing_requires_read.txt"
    File.write(path, "old\n")
    workspace = Kward::Workspace.new

    result = workspace.write_file(path, "new\n", read_paths: []) { true }

    assert_equal "Error: existing file must be read before writing: #{path}", result
    assert_equal "old\n", File.read(path)
  ensure
    File.delete(path) if path && File.exist?(path)
  end

  def test_accepted_write_modifies_new_file
    path = "kward_accepted_new.txt"
    workspace = Kward::Workspace.new

    result = workspace.write_file(path, "hello\n", read_paths: []) { true }

    assert_equal "Wrote 6 bytes to #{path}", result
    assert_equal "hello\n", File.read(path)
  ensure
    File.delete(path) if path && File.exist?(path)
  end

  def test_declined_write_does_not_modify_file
    path = "kward_declined_write.txt"
    workspace = Kward::Workspace.new

    result = workspace.write_file(path, "hello\n", read_paths: []) { false }

    assert_equal "Declined: write_file was not approved for #{path}", result
    refute File.exist?(path)
  ensure
    File.delete(path) if path && File.exist?(path)
  end

  def test_existing_file_can_be_written_after_successful_read_and_confirmation
    path = "kward_existing_after_read.txt"
    File.write(path, "old\n")
    workspace = Kward::Workspace.new
    conversation = Kward::Conversation.new
    content = workspace.read_file(path)
    conversation.mark_read(workspace.resolved_path(path)) unless content.start_with?("Error:")

    result = workspace.write_file(path, "new\n", read_paths: conversation.read_paths) { true }

    assert_equal "Wrote 4 bytes to #{path}", result
    assert_equal "new\n", File.read(path)
  ensure
    File.delete(path) if path && File.exist?(path)
  end

  def test_tool_registry_write_runs_without_confirmation
    path = "kward_confirm_tool.txt"
    prompt = FakePrompt.new([], confirmations: [false])
    conversation = Kward::Conversation.new
    registry = Kward::ToolRegistry.new(prompt: prompt)

    registry.dispatch(tool_call("write_file", path: path, content: "hello\n"), conversation)

    refute_includes prompt.output, "\nWrite request> #{path} (6 bytes)"
    assert_equal "hello\n", File.read(path)
  ensure
    File.delete(path) if path && File.exist?(path)
  end

  def test_edit_file_requires_prior_successful_read
    path = "kward_edit_requires_read.txt"
    File.write(path, "old\n")
    workspace = Kward::Workspace.new

    result = workspace.edit_file(path, [{ "old_text" => "old", "new_text" => "new" }], read_paths: [])

    assert_equal "Error: existing file must be read before editing: #{path}", result
    assert_equal "old\n", File.read(path)
  ensure
    File.delete(path) if path && File.exist?(path)
  end

  def test_edit_file_applies_exact_replacement_after_read_and_returns_diff
    path = "kward_edit_exact.txt"
    File.write(path, "one\ntwo\nthree\n")
    workspace = Kward::Workspace.new
    conversation = Kward::Conversation.new
    content = workspace.read_file(path)
    conversation.mark_read(workspace.resolved_path(path)) unless content.start_with?("Error:")

    result = workspace.edit_file(path, [{ "old_text" => "two", "new_text" => "TWO" }], read_paths: conversation.read_paths)

    assert_includes result, "Edited #{path}: replaced 1 block(s)"
    assert_includes result, "--- #{path}"
    assert_includes result, "-two"
    assert_includes result, "+TWO"
    assert_equal "one\nTWO\nthree\n", File.read(path)
  ensure
    File.delete(path) if path && File.exist?(path)
  end

  def test_edit_file_applies_multiple_disjoint_edits_against_original_content
    path = "kward_edit_multiple.txt"
    File.write(path, "alpha\nbeta\ngamma\n")
    workspace = Kward::Workspace.new
    conversation = Kward::Conversation.new
    content = workspace.read_file(path)
    conversation.mark_read(workspace.resolved_path(path)) unless content.start_with?("Error:")

    result = workspace.edit_file(
      path,
      [
        { "old_text" => "alpha", "new_text" => "ALPHA" },
        { "old_text" => "gamma", "new_text" => "GAMMA" }
      ],
      read_paths: conversation.read_paths
    )

    assert_includes result, "Edited #{path}: replaced 2 block(s)"
    assert_equal "ALPHA\nbeta\nGAMMA\n", File.read(path)
  ensure
    File.delete(path) if path && File.exist?(path)
  end

  def test_edit_file_rejects_empty_duplicate_missing_and_overlapping_edits_without_changes
    path = "kward_edit_invalid.txt"
    File.write(path, "abc abc\n")
    workspace = Kward::Workspace.new
    conversation = Kward::Conversation.new
    content = workspace.read_file(path)
    conversation.mark_read(workspace.resolved_path(path)) unless content.start_with?("Error:")

    assert_equal "Error: edits[0].old_text must not be empty", workspace.edit_file(path, [{ "old_text" => "", "new_text" => "x" }], read_paths: conversation.read_paths)
    assert_match(/appears 2 times/, workspace.edit_file(path, [{ "old_text" => "abc", "new_text" => "x" }], read_paths: conversation.read_paths))
    assert_equal "Error: edits[0].old_text was not found in #{path}", workspace.edit_file(path, [{ "old_text" => "missing", "new_text" => "x" }], read_paths: conversation.read_paths)
    assert_equal "Error: edits[0] and edits[1] overlap in #{path}", workspace.edit_file(path, [{ "old_text" => "abc ", "new_text" => "x" }, { "old_text" => "bc abc", "new_text" => "y" }], read_paths: conversation.read_paths)
    assert_equal "abc abc\n", File.read(path)
  ensure
    File.delete(path) if path && File.exist?(path)
  end

  def test_tool_registry_edit_file_updates_existing_read_file
    path = "kward_edit_tool.txt"
    File.write(path, "hello world\n")
    conversation = Kward::Conversation.new
    registry = Kward::ToolRegistry.new

    registry.dispatch(tool_call("read_file", path: path), conversation)
    result = registry.dispatch(tool_call("edit_file", path: path, edits: [{ old_text: "world", new_text: "there" }]), conversation)

    assert_includes result, "Edited #{path}: replaced 1 block(s)"
    assert_equal "hello there\n", File.read(path)
  ensure
    File.delete(path) if path && File.exist?(path)
  end

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

  def test_symlink_escape_remains_rejected
    skip "symlinks are unavailable" unless File.respond_to?(:symlink)

    outside = File.expand_path("../kward_symlink_escape.txt", Dir.pwd)
    link = "kward_symlink_escape_link.txt"
    File.write(outside, "outside\n")
    File.symlink(outside, link)
    workspace = Kward::Workspace.new

    assert_match(/Error: path outside workspace:/, workspace.read_file(link))
    assert_match(/Error: path outside workspace:/, workspace.write_file(link, "nope\n", read_paths: []) { true })
    assert_match(/Error: path outside workspace:/, workspace.edit_file(link, [{ "old_text" => "outside", "new_text" => "nope" }], read_paths: []))
    assert_equal "outside\n", File.read(outside)
  ensure
    File.delete(link) if link && File.symlink?(link)
    File.delete(outside) if outside && File.exist?(outside)
  end

  def test_run_shell_command_runs_in_workspace
    output = Kward::Workspace.new.run_shell_command("ruby -e 'puts Dir.pwd; puts 2 + 2'")

    assert_includes output, "Exit status: 0"
    assert_includes output, Dir.pwd
    assert_includes output, "4"
  end

  def test_run_shell_command_times_out
    output = Kward::Workspace.new.run_shell_command("ruby -e 'sleep 2'", timeout_seconds: 1)

    assert_equal "Error: command timed out after 1 seconds", output
  end

  def test_tool_registry_shell_command_runs_without_confirmation
    prompt = FakePrompt.new([], confirmations: [false])
    conversation = Kward::Conversation.new
    registry = Kward::ToolRegistry.new(prompt: prompt)

    result = registry.dispatch(tool_call("run_shell_command", command: "echo ok"), conversation)

    refute_includes prompt.output, "\nShell command request> echo ok"
    assert_includes result, "ok"
  end

  def test_piped_prompt_reads_non_tty_input
    cli = Kward::CLI.new(stdin: FakeInput.new("hello from stdin\n", tty: false), client: FakeClient.new([]))

    assert_equal "hello from stdin", cli.piped_prompt
  end

  def test_piped_prompt_ignores_tty_input
    cli = Kward::CLI.new(stdin: FakeInput.new("ignored", tty: true), client: FakeClient.new([]))

    assert_equal "", cli.piped_prompt
  end

  def ask_prompt_with_input(keys)
    input, writer = IO.pipe
    output = StringIO.new
    writer.write(keys)
    writer.close
    prompt = Kward::PromptInterface.new(input: input, output: output)

    prompt.ask("You>")
  ensure
    input&.close unless input&.closed?
  end

  def poll_prompt_until(prompt, timeout: 1)
    deadline = Time.now + timeout
    loop do
      result = prompt.poll_input
      return result if yield(result)
      raise "timed out waiting for prompt input" if Time.now > deadline

      sleep 0.01
    end
  end

  def strip_ansi(text)
    Kward::ANSI.strip(text)
  end

  def tool_call(name, args)
    {
      "id" => "call_#{name}",
      "type" => "function",
      "function" => {
        "name" => name,
        "arguments" => JSON.dump(args)
      }
    }
  end

  def assistant_tool_call(name, args)
    { "role" => "assistant", "content" => nil, "tool_calls" => [tool_call(name, args)] }
  end

  def fake_response(code, body)
    Kward::WebResearch::NetHttpClient::Response.new(code: code, body: body)
  end

  class FakeHttpClient
    attr_reader :requests

    def initialize(routes)
      @routes = routes
      @requests = []
    end

    def get(url, headers: {})
      request("GET", url, headers: headers)
    end

    def post(url, form:, headers: {})
      request("POST", url, headers: headers, form: form)
    end

    private

    def request(method, url, headers:, form: nil)
      @requests << { method: method, url: url, headers: headers, form: form }
      response = @routes[[method, url]] || @routes[url]
      raise "unexpected URL: #{method} #{url}" unless response

      response
    end
  end

  class FakeWebResearch
    attr_reader :calls

    def initialize(result)
      @result = result
      @calls = []
    end

    def search(args)
      @calls << args
      @result
    end
  end

  class FakeClient
    def initialize(responses)
      @responses = responses
    end

    def chat(_messages, tools: [])
      @responses.shift
    end
  end

  class FakeOAuth
    def initialize(access_token)
      @access_token = access_token
    end

    attr_reader :access_token
  end

  class RecordingClient
    attr_reader :seen_messages

    def initialize(responses)
      @responses = responses
      @seen_messages = []
    end

    def chat(messages, tools: [])
      @seen_messages << messages.map(&:dup)
      { "role" => "assistant", "content" => @responses.shift }
    end
  end

  class StreamingRecordingClient
    attr_reader :seen_messages

    def initialize(responses)
      @responses = responses
      @seen_messages = []
    end

    def chat(messages, tools: [], on_assistant_delta: nil)
      @seen_messages << messages.map(&:dup)
      content = @responses.shift
      on_assistant_delta&.call(content)
      sleep 0.12
      { "role" => "assistant", "content" => content }
    end
  end

  class FakePrompt
    attr_reader :output

    def initialize(inputs, confirmations: [])
      @inputs = inputs
      @confirmations = confirmations
      @output = []
    end

    def ask(_message)
      @inputs.shift
    end

    def yes?(_message, default: false)
      @confirmations.empty? ? default : @confirmations.shift
    end

    def say(message)
      @output << message
    end
  end

  class FakeInput
    def initialize(content, tty:)
      @content = content
      @tty = tty
    end

    def tty?
      @tty
    end

    def read
      @content
    end
  end
end

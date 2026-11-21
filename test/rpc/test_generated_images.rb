require_relative "test_support"

class TestRPCGeneratedImages < KwardTestCase
  include KwardRPCTestSupport

  class ImageClient
    PNG = Base64.strict_decode64("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aY+0AAAAASUVORK5CYII=").freeze

    def current_provider = "Codex"
    def generate_codex_image(*, **) = PNG

    def chat(messages, tools:, **)
      base = { "role" => "assistant", "provider" => "Codex", "model" => "test" }
      if messages.last["role"] == "tool" || messages.last[:role] == "tool" || tools.none? { |schema| Kward::ToolCall.name(schema) == "generate_image" }
        base.merge("content" => "Done")
      else
        base.merge("tool_calls" => [{ "id" => "draw", "function" => { "name" => "generate_image", "arguments" => '{"prompt":"A red square"}' } }])
      end
    end
  end

  def test_codex_turn_previews_are_scoped_to_the_generating_session
    Dir.mktmpdir do |root|
      config = File.join(root, "config")
      FileUtils.mkdir_p(config)
      with_env("KWARD_CONFIG_DIR" => config, "KWARD_CONFIG_PATH" => File.join(config, "config.json")) do
        server = Kward::RPC::Server.new(input: StringIO.new, output: StringIO.new, error_output: StringIO.new, client: ImageClient.new)
        dispatch = ->(method, params) { server.send(:dispatch, method, params) }
        session = dispatch.call("sessions/create", "workspaceRoot" => root, "name" => "Origin")
        turn = dispatch.call("turns/start", "sessionId" => session[:id], "input" => "Draw a square")
        wait_until { server.session_manager.turn_status(turn_id: turn[:id])[:status] == "completed" }
        events = server.session_manager.turn_events(turn_id: turn[:id])[:events]
        ready = events.find { |event| event[:type] == "imageReady" }.fetch(:payload)
        assert_equal "draw", ready[:toolCallId]
        refute ready.key?(:data)
        args = { "sessionId" => session[:id], "imageId" => ready[:id] }
        fetched = dispatch.call("images/fetch", args)
        assert_equal ImageClient::PNG, Base64.strict_decode64(fetched[:data])
        assert_nil fetched[:nextOffset]
        other = dispatch.call("sessions/create", "workspaceRoot" => root, "name" => "Other")
        assert_raises(ArgumentError) { dispatch.call("images/fetch", args.merge("sessionId" => other[:id])) }
        assert_raises(ArgumentError) { dispatch.call("images/saveToProject", args.merge("directory" => "..")) }
        saved = dispatch.call("images/saveToProject", args)
        assert_equal ImageClient::PNG, File.binread(saved[:path])
        assert dispatch.call("images/discard", args)[:discarded]
        assert_raises(ArgumentError) { dispatch.call("images/fetch", args) }
        assert_path_exists saved[:path]
      ensure
        server&.shutdown
      end
    end
  end
end

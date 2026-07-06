require_relative "test_helper"

class TestMCP < KwardTestCase
  class FakeTransport
    attr_reader :requests, :notifications

    def initialize(tools: [], call_result: {})
      @tools = tools
      @call_result = call_result
      @requests = []
      @notifications = []
    end

    def request(method, params = nil)
      @requests << [method, params]
      case method
      when "initialize"
        { "protocolVersion" => Kward::MCP::PROTOCOL_VERSION }
      when "tools/list"
        { "tools" => @tools }
      when "tools/call"
        @call_result
      else
        {}
      end
    end

    def notify(method, params = nil)
      @notifications << [method, params]
    end

    def close; end
  end

  class FakeMCPClient
    attr_reader :name, :calls

    def initialize
      @name = "safari-mcp-stp"
      @calls = []
    end

    def list_tools
      [
        {
          "name" => "inspect.page",
          "description" => "Inspect the active page",
          "inputSchema" => {
            "type" => "object",
            "properties" => { "selector" => { "type" => "string" } },
            "required" => ["selector"],
            "additionalProperties" => false
          }
        }
      ]
    end

    def call_tool(name, arguments)
      @calls << [name, arguments]
      {
        "content" => [{ "type" => "text", "text" => "DOM looks good" }],
        "structuredContent" => { "ok" => true }
      }
    end
  end

  def test_client_initializes_lists_tools_and_calls_tool
    transport = FakeTransport.new(
      tools: [{ "name" => "ping", "inputSchema" => { "type" => "object" } }],
      call_result: { "content" => [{ "type" => "text", "text" => "pong" }] }
    )
    client = Kward::MCP::Client.new(name: "server", transport: transport)

    assert_equal [{ "name" => "ping", "inputSchema" => { "type" => "object" } }], client.list_tools
    assert_equal({ "content" => [{ "type" => "text", "text" => "pong" }] }, client.call_tool("ping", { "x" => 1 }))

    assert_equal "initialize", transport.requests[0][0]
    assert_equal "notifications/initialized", transport.notifications[0][0]
    assert_equal "tools/list", transport.requests[1][0]
    assert_equal ["tools/call", { name: "ping", arguments: { "x" => 1 } }], transport.requests[2]
  end

  def test_server_config_builds_clients_from_mcp_servers
    config = {
      "mcpServers" => {
        "safari" => {
          "command" => "/bin/echo",
          "args" => ["--mcp"],
          "env" => { "SAFARI" => "1" },
          "timeout_seconds" => 2
        },
        "disabled" => { "command" => "/bin/false", "enabled" => false }
      }
    }

    clients = Kward::MCP::ServerConfig.clients_from_config(config)

    assert_equal 1, clients.length
    assert_equal "safari", clients.first.name
  end

  def test_tool_registry_exposes_and_dispatches_mcp_tools
    client = FakeMCPClient.new
    registry = Kward::ToolRegistry.new(mcp_clients: [client], web_search_enabled: false, skills: [])

    schema = registry.schemas.find { |entry| entry.dig(:function, :name) == "safari-mcp-stp__inspect_page" }
    refute_nil schema
    assert_equal "Inspect the active page", schema.dig(:function, :description)
    assert_equal ["selector"], schema.dig(:function, :parameters, "required")
    assert_equal({ source: "mcp", displayName: "safari-mcp-stp.inspect.page", serverName: "safari-mcp-stp", remoteName: "inspect.page" }, schema[:metadata])

    conversation = Kward::Conversation.new
    result = registry.dispatch(
      {
        "id" => "call-1",
        "function" => {
          "name" => "safari-mcp-stp__inspect_page",
          "arguments" => JSON.generate("selector" => "body")
        }
      },
      conversation
    )

    assert_includes result, "DOM looks good"
    assert_includes result, '"ok": true'
    assert_equal [["inspect.page", { "selector" => "body" }]], client.calls
  end

  def test_default_config_includes_empty_mcp_servers
    assert_equal({}, Kward::ConfigFiles.default_config["mcpServers"])
  end
end

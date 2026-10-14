require "net/http"
require_relative "test_helper"

class TestPluginHTTPServer < KwardTestCase
  def test_host_manages_a_loopback_http_listener
    Dir.mktmpdir do |directory|
      host = Kward::PluginHost.new(id: "example.proxy", version: "1.0", api_version: "1", storage_root: directory)
      server = host.http_server do |request, response|
        response.status = 200
        response["Content-Type"] = "text/plain"
        response.body = request.body.to_s
      end
      server.start

      response = Net::HTTP.post(URI("http://127.0.0.1:#{server.port}/test"), "hello")
      assert_equal "200", response.code
      assert_equal "hello", response.body

      host.shutdown
      assert_raises(Errno::ECONNREFUSED) { TCPSocket.new("127.0.0.1", server.port) }
    end
  end

  def test_listener_rejects_non_loopback_bind_addresses
    Dir.mktmpdir do |directory|
      host = Kward::PluginHost.new(id: "example.proxy", version: "1.0", api_version: "1", storage_root: directory)

      assert_raises(ArgumentError) { host.http_server(host: "0.0.0.0") { |_request, _response| } }
      assert_raises(ArgumentError) { host.http_server(host: "192.0.2.1") { |_request, _response| } }
    end
  end

  def test_listener_rejects_nonpositive_resource_limits
    assert_raises(ArgumentError) { Kward::PluginHTTPServer.new(max_body_bytes: 0) { } }
    assert_raises(ArgumentError) { Kward::PluginHTTPServer.new(request_timeout: 0) { } }
    assert_raises(ArgumentError) { Kward::PluginHTTPServer.new(max_clients: 0) { } }
  end
end

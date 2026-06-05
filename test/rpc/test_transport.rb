require_relative "test_support"

class TestRPCTransport < KwardTestCase
  include KwardRPCTestSupport

  def test_transport_reads_and_writes_content_length_messages
    input = StringIO.new(framed({ jsonrpc: "2.0", id: 1, method: "initialize" }))
    output = StringIO.new
    transport = Kward::RPC::Transport.new(input: input, output: output)

    assert_equal({ "jsonrpc" => "2.0", "id" => 1, "method" => "initialize" }, transport.read_message)
    transport.write_message(jsonrpc: "2.0", id: 1, result: { ok: true })

    assert_equal({ "jsonrpc" => "2.0", "id" => 1, "result" => { "ok" => true } }, read_framed_messages(output).first)
  end
end

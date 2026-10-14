require "ipaddr"
require "webrick"

module Kward
  # Small, plugin-owned HTTP listener constrained to loopback.
  class PluginHTTPServer
    DEFAULT_MAX_BODY_BYTES = 1_048_576
    DEFAULT_REQUEST_TIMEOUT = 30

    attr_reader :host, :requested_port

    def initialize(host: "127.0.0.1", port: 0, max_body_bytes: DEFAULT_MAX_BODY_BYTES, request_timeout: DEFAULT_REQUEST_TIMEOUT, max_clients: 8, &handler)
      raise ArgumentError, "Plugin HTTP server requires a handler" unless handler
      raise ArgumentError, "Plugin HTTP server must bind to loopback" unless IPAddr.new(host).loopback?
      raise ArgumentError, "Plugin HTTP server port must be between 0 and 65535" unless Integer(port).between?(0, 65_535)
      raise ArgumentError, "Plugin HTTP server body limit must be positive" unless Integer(max_body_bytes).positive?
      raise ArgumentError, "Plugin HTTP server request timeout must be positive" unless Float(request_timeout).positive?
      raise ArgumentError, "Plugin HTTP server client limit must be positive" unless Integer(max_clients).positive?

      @host = host
      @requested_port = Integer(port)
      @handler = handler
      @server = WEBrick::HTTPServer.new(
        BindAddress: host,
        Port: @requested_port,
        MaxReqBytes: Integer(max_body_bytes),
        RequestTimeout: Float(request_timeout),
        MaxClients: Integer(max_clients),
        AccessLog: [],
        Logger: WEBrick::Log.new(File::NULL)
      )
      @thread = nil
      @mutex = Mutex.new
    end

    def start
      @mutex.synchronize do
        return self if @thread&.alive?

        @server.mount_proc("/") { |request, response| @handler.call(request, response) }
        @thread = Thread.new { @server.start }
        @thread.report_on_exception = false
      end
      wait_until_ready
      self
    end

    def wait
      @thread&.join
    end

    def stop
      thread = @mutex.synchronize do
        current = @thread
        @server.shutdown if current&.alive?
        @thread = nil
        current
      end
      thread&.join(2)
      self
    end

    def port
      @port || requested_port
    end

    private

    def wait_until_ready
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
      loop do
        if @server.status == :Running
          @port = @server.listeners.first&.addr&.[](1) || requested_port
          return
        end
        raise @thread.value unless @thread.alive?
        raise "Plugin HTTP server did not start" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

        sleep 0.01
      end
    end
  end
end

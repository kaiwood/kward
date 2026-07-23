require "stringio"
require_relative "../config_files"
require_relative "../rpc/server"
require_relative "gateway"
require_relative "manager"

module Kward
  module Transport
    # Builds the Kward runtime needed by foreground transport processes.
    class Runtime
      attr_reader :manager

      def initialize(client:)
        @server = RPC::Server.new(
          input: StringIO.new,
          output: StringIO.new,
          error_output: $stderr,
          client: client
        )
        @manager = Manager.new(
          registry: @server.session_manager.plugin_registry,
          gateway: lambda { |transport_id|
            Gateway.new(session_manager: @server.session_manager, transport_id: transport_id)
          },
          config_root: ConfigFiles.config_dir
        )
      end

      def shutdown
        @manager.shutdown
        @server.shutdown
        nil
      end
    end
  end
end

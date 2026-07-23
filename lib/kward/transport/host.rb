require_relative "../deep_copy"
require_relative "store"

module Kward
  module Transport
    # Public dependencies made available to a running transport adapter.
    class Host
      class UnavailableGateway < StandardError; end

      SessionHandle = Data.define(:id, :workspace_root, :name)
      TurnHandle = Data.define(:id, :session_id)

      # Creates a host for one registered transport instance.
      def initialize(transport_id:, gateway: nil, config: {}, storage: nil, policy: nil, logger: nil)
        @transport_id = transport_id.to_s.freeze
        @gateway = gateway
        @config = freeze_copy(config)
        @storage = storage || Store.new(@transport_id)
        @policy = policy || AllowAllPolicy.new
        @logger = logger || Logger.new($stderr)
        @sessions = Sessions.new(self)
      end

      attr_reader :transport_id, :config, :storage, :policy, :logger

      def sessions
        @sessions
      end

      def gateway
        return @gateway if @gateway

        raise UnavailableGateway, "transport host has no session gateway"
      end

      # Resolves an external conversation to a normal Kward session.
      class Sessions
        def initialize(host)
          @host = host
        end

        def resolve(conversation:, actor:, workspace_root: nil, name: nil)
          result = @host.gateway.resolve_transport_session(
            transport_id: @host.transport_id,
            conversation: conversation,
            actor: actor,
            workspace_root: workspace_root,
            name: name
          )
          Session.new(@host, normalize_handle(result))
        end

        private

        def normalize_handle(result)
          return result if result.is_a?(SessionHandle)
          return SessionHandle.new(**result.transform_keys(&:to_sym)) if result.is_a?(Hash)

          raise TypeError, "session gateway returned an invalid session handle"
        end
      end

      # Narrow session operations exposed to a transport.
      class Session
        attr_reader :id, :workspace_root, :name

        def initialize(host, handle)
          @host = host
          @id = handle.id.to_s.freeze
          @workspace_root = handle.workspace_root.to_s.freeze
          @name = handle.name&.to_s&.freeze
        end

        def start_turn(input, attachments: [], options: {}, streaming_behavior: nil)
          result = @host.gateway.start_transport_turn(
            session_id: @id,
            input: input.to_s,
            attachments: attachments,
            options: options,
            streaming_behavior: streaming_behavior
          )
          handle = result.is_a?(TurnHandle) ? result : TurnHandle.new(**result.transform_keys(&:to_sym))
          Turn.new(@host, handle)
        end

        def transcript
          @host.gateway.transport_transcript(session_id: @id)
        end

        def answer_interaction(request_id:, answer:)
          @host.gateway.answer_transport_interaction(session_id: @id, request_id: request_id, answer: answer)
        end
      end

      # Handle for an asynchronously running Kward turn.
      class Turn
        attr_reader :id, :session_id

        def initialize(host, handle)
          @host = host
          @id = handle.id.to_s.freeze
          @session_id = handle.session_id.to_s.freeze
        end

        def subscribe(after: nil, &block)
          raise ArgumentError, "turn subscription requires a block" unless block

          @host.gateway.subscribe_transport_turn(turn_id: @id, after: after, &block)
        end

        def events(after: nil)
          @host.gateway.transport_turn_events(turn_id: @id, after: after)
        end

        def status
          @host.gateway.transport_turn_status(turn_id: @id)
        end

        def cancel
          @host.gateway.cancel_transport_turn(turn_id: @id)
        end
      end

      # Default policy used by the host until a configured policy is supplied.
      class AllowAllPolicy
        def authorize(**)
          true
        end
      end

      private

      def freeze_copy(value)
        DeepCopy.freeze(DeepCopy.dup(value))
      end
    end
  end
end

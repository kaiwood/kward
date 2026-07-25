require_relative "../deep_copy"
require_relative "store"

module Kward
  module Transport
    # Public dependencies made available to a running transport adapter.
    class Host
      class UnavailableGateway < StandardError; end
      class PolicyDenied < StandardError; end

      SessionHandle = Data.define(:id, :workspace_root, :name)
      TurnHandle = Data.define(:id, :session_id)
      PluginChatHandle = Data.define(:id, :type_id, :scope_key, :name)
      PluginChatTurnHandle = Data.define(:id, :chat_id)

      # Creates a host for one registered transport instance.
      def initialize(transport_id:, gateway: nil, plugin_chat_gateway: nil, config: {}, storage: nil, policy: nil, logger: nil, execution_profile: nil)
        unless execution_profile.nil? || execution_profile.is_a?(ExecutionProfile)
          raise ArgumentError, "execution_profile must be a Transport::ExecutionProfile"
        end

        @transport_id = transport_id.to_s.freeze
        @gateway = gateway
        @plugin_chat_gateway = plugin_chat_gateway
        @config = freeze_copy(config)
        @storage = storage || Store.new(@transport_id)
        @policy = policy || AllowAllPolicy.new
        @execution_profile = execution_profile
        @logger = logger || Logger.new($stderr)
        @sessions = Sessions.new(self)
        @plugin_chats = PluginChats.new(self)
        @interactions = Interactions.new(self)
      end

      attr_reader :transport_id, :config, :storage, :policy, :execution_profile, :logger

      def sessions
        @sessions
      end

      def interactions
        @interactions
      end

      def plugin_chats
        @plugin_chats
      end

      def gateway
        return @gateway if @gateway

        raise UnavailableGateway, "transport host has no session gateway"
      end

      def authorize!(action, **attributes)
        return true if policy.authorize(action: action, transport_id: @transport_id, **attributes) == true

        raise PolicyDenied, "Transport policy denied #{action}"
      end

      def plugin_chat_gateway
        return @plugin_chat_gateway if @plugin_chat_gateway

        raise UnavailableGateway, "transport host has no plugin chat gateway"
      end

      # Reads a transport secret from private config or an explicit environment
      # variable without exposing it through status or logging helpers.
      def secret(key, env: nil)
        key = key.to_s
        raise ArgumentError, "secret key is required" if key.empty?

        value = config[key]
        value = ENV.fetch(env.to_s) if value.nil? && env
        value = ENV[default_secret_env_name(key)] if value.nil?
        value.to_s unless value.nil?
      end

      def shutdown
        @gateway&.shutdown
        @plugin_chat_gateway&.shutdown
        nil
      end

      # Resolves an external conversation to a normal Kward session.
      class Sessions
        def initialize(host)
          @host = host
        end

        def resolve(conversation:, actor:, workspace_root: nil, name: nil)
          workspace_root = fixed_workspace_root(workspace_root)
          @host.authorize!(:resolve_session, conversation: conversation, actor: actor, workspace_root: workspace_root)
          result = @host.gateway.resolve_transport_session(
            transport_id: @host.transport_id,
            conversation: conversation,
            actor: actor,
            workspace_root: workspace_root,
            name: name,
            execution_profile: @host.execution_profile
          )
          Session.new(@host, normalize_handle(result), actor)
        end

        private

        def fixed_workspace_root(workspace_root)
          return workspace_root unless @host.execution_profile&.workspace_mode == :fixed

          configured = @host.config["workspace"] || @host.config[:workspace]
          raise ArgumentError, "fixed execution profile requires a configured workspace" if configured.to_s.empty?

          configured.to_s
        end

        def normalize_handle(result)
          return result if result.is_a?(SessionHandle)
          return SessionHandle.new(**result.transform_keys(&:to_sym)) if result.is_a?(Hash)

          raise TypeError, "session gateway returned an invalid session handle"
        end
      end

      # Narrow session operations exposed to a transport.
      class Session
        attr_reader :id, :workspace_root, :name

        def initialize(host, handle, actor)
          @host = host
          @actor = actor
          @id = handle.id.to_s.freeze
          @workspace_root = handle.workspace_root.to_s.freeze
          @name = handle.name&.to_s&.freeze
        end

        def start_turn(input, attachments: [], options: {}, streaming_behavior: nil)
          @host.authorize!(:start_turn, actor: @actor, session_id: @id, input: input.to_s)
          result = @host.gateway.start_transport_turn(
            session_id: @id,
            input: input.to_s,
            attachments: attachments,
            options: options,
            streaming_behavior: streaming_behavior,
            execution_profile: @host.execution_profile
          )
          handle = result.is_a?(TurnHandle) ? result : TurnHandle.new(**result.transform_keys(&:to_sym))
          Turn.new(@host, handle, @actor)
        end

        def transcript
          @host.authorize!(:read_transcript, actor: @actor, session_id: @id)
          @host.gateway.transport_transcript(session_id: @id)
        end

        def answer_interaction(request_id:, answer:)
          if @host.execution_profile&.approval_mode == :deny
            raise PolicyDenied, "Transport execution profile does not allow interactions"
          end

          @host.authorize!(:answer_interaction, actor: @actor, session_id: @id, request_id: request_id)
          @host.gateway.answer_transport_interaction(session_id: @id, request_id: request_id, answer: answer)
        end
      end

      # Resolves an external conversation to a plugin-owned chat.
      class PluginChats
        def initialize(host)
          @host = host
        end

        def resolve(type_id:, conversation:, actor:, scope_key: nil, descriptor: {})
          scope_key ||= conversation.external_id
          @host.authorize!(:resolve_plugin_chat, type_id: type_id.to_s, conversation: conversation, actor: actor, scope_key: scope_key)
          result = @host.plugin_chat_gateway.resolve_transport_chat(
            transport_id: @host.transport_id,
            type_id: type_id,
            conversation: conversation,
            actor: actor,
            scope_key: scope_key,
            descriptor: descriptor,
            workspace_root: workspace_root
          )
          PluginChat.new(@host, normalize_handle(result), actor)
        end

        private

        def workspace_root
          return @host.config["workspace"] || @host.config[:workspace] if @host.execution_profile&.workspace_mode == :fixed

          @host.config["workspace"] || @host.config[:workspace] || Dir.pwd
        end

        def normalize_handle(result)
          return result if result.is_a?(PluginChatHandle)
          return PluginChatHandle.new(**result.transform_keys(&:to_sym)) if result.is_a?(Hash)

          raise TypeError, "plugin chat gateway returned an invalid chat handle"
        end
      end

      # Narrow plugin-chat operations exposed to a transport.
      class PluginChat
        attr_reader :id, :type_id, :scope_key, :name

        def initialize(host, handle, actor)
          @host = host
          @actor = actor
          @id = handle.id.to_s.freeze
          @type_id = handle.type_id.to_s.freeze
          @scope_key = handle.scope_key.to_s.freeze
          @name = handle.name&.to_s&.freeze
        end

        def start_turn(input, attachments: [], options: {}, streaming_behavior: nil)
          @host.authorize!(:start_plugin_chat_turn, actor: @actor, chat_id: @id, type_id: @type_id, input: input.to_s)
          if @host.execution_profile && !@host.execution_profile.attachments && !Array(attachments).empty?
            raise PolicyDenied, "Transport execution profile does not allow attachments"
          end
          unless options.nil? || options.empty?
            raise ArgumentError, "plugin chat turns do not support options"
          end
          unless streaming_behavior.nil? || %i[aggregate none].include?(streaming_behavior.to_sym)
            raise ArgumentError, "plugin chat turns do not support #{streaming_behavior} streaming"
          end

          result = @host.plugin_chat_gateway.start_transport_plugin_chat_turn(
            chat_id: @id,
            input: input,
            attachments: attachments,
            streaming_behavior: streaming_behavior,
            execution_profile: @host.execution_profile
          )
          handle = result.is_a?(PluginChatTurnHandle) ? result : PluginChatTurnHandle.new(**result.transform_keys(&:to_sym))
          PluginChatTurn.new(@host, handle, @actor)
        end

        def transcript
          @host.authorize!(:read_plugin_chat_transcript, actor: @actor, chat_id: @id, type_id: @type_id)
          @host.plugin_chat_gateway.transport_plugin_chat_transcript(chat_id: @id)
        end
      end

      # Handle for an asynchronously running plugin-chat turn.
      class PluginChatTurn
        attr_reader :id, :chat_id

        def initialize(host, handle, actor)
          @host = host
          @actor = actor
          @id = handle.id.to_s.freeze
          @chat_id = handle.chat_id.to_s.freeze
        end

        def subscribe(after: nil, &block)
          raise ArgumentError, "plugin chat turn subscription requires a block" unless block

          @host.plugin_chat_gateway.subscribe_transport_plugin_chat_turn(turn_id: @id, after: after, &block)
        end

        def events(after: nil)
          @host.plugin_chat_gateway.transport_plugin_chat_turn_events(turn_id: @id, after: after)
        end

        def status
          @host.plugin_chat_gateway.transport_plugin_chat_turn_status(turn_id: @id)
        end

        def cancel
          @host.authorize!(:cancel_plugin_chat_turn, actor: @actor, chat_id: @chat_id, turn_id: @id)
          @host.plugin_chat_gateway.cancel_transport_plugin_chat_turn(turn_id: @id)
        end
      end

      # Subscribes to questions and tool approval requests for this transport.
      class Interactions
        def initialize(host)
          @host = host
        end

        def subscribe(&block)
          raise ArgumentError, "interaction subscription requires a block" unless block

          @host.gateway.subscribe_transport_interactions(&block)
        end
      end

      # Handle for an asynchronously running Kward turn.
      class Turn
        attr_reader :id, :session_id

        def initialize(host, handle, actor)
          @host = host
          @actor = actor
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
          @host.authorize!(:cancel_turn, actor: @actor, session_id: @session_id, turn_id: @id)
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

      def default_secret_env_name(key)
        "KWARD_TRANSPORT_#{@transport_id.gsub(/[^A-Za-z0-9]/, "_").upcase}_#{key.gsub(/[^A-Za-z0-9]/, "_").upcase}"
      end

      def freeze_copy(value)
        DeepCopy.freeze(DeepCopy.dup(value))
      end
    end
  end
end

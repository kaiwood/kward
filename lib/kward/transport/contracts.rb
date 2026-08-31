# Frontend-neutral external transport contracts.
require "logger"
require_relative "../deep_copy"

# Namespace for frontend-neutral external transport contracts.
module Kward
  module Transport
    STREAMING_MODES = %i[native edit aggregate none].freeze

    Actor = Data.define(:id, :display_name, :metadata)
    Attachment = Data.define(:name, :mime_type, :data, :url, :metadata)
    ConversationKey = Data.define(:transport_id, :external_id)
    InboundMessage = Data.define(
      :conversation,
      :message_id,
      :actor,
      :text,
      :attachments,
      :reply_context,
      :idempotency_key,
      :metadata
    )
    TurnEvent = Data.define(:type, :session_id, :turn_id, :sequence, :payload)
    InteractionRequest = Data.define(
      :id,
      :session_id,
      :turn_id,
      :kind,
      :prompt,
      :choices,
      :expires_at,
      :metadata
    )
    Capabilities = Data.define(:inbound, :outbound, :streaming, :limits)
    ExecutionProfile = Data.define(
      :id,
      :tool_mode,
      :allowed_tools,
      :disabled_tools,
      :plugin_commands,
      :approval_mode,
      :memory,
      :attachments,
      :workspace_mode,
      :prompt_context
    )

    TOOL_MODES = %i[all none allowlist].freeze
    APPROVAL_MODES = %i[default ask deny].freeze
    MEMORY_MODES = %i[default none].freeze
    WORKSPACE_MODES = %i[session fixed].freeze

    module_function

    def actor(id:, display_name: nil, metadata: {})
      Actor.new(
        id: required_string(id, "actor id"),
        display_name: optional_string(display_name),
        metadata: frozen_copy(metadata)
      )
    end

    def attachment(name: nil, mime_type:, data: nil, url: nil, metadata: {})
      raise ArgumentError, "attachment requires data or url" if data.nil? && url.nil?
      raise ArgumentError, "attachment cannot contain both data and url" unless data.nil? || url.nil?

      Attachment.new(
        name: optional_string(name),
        mime_type: required_string(mime_type, "attachment MIME type"),
        data: data&.dup&.freeze,
        url: url && required_string(url, "attachment URL"),
        metadata: frozen_copy(metadata)
      )
    end

    def conversation_key(transport_id:, external_id:)
      ConversationKey.new(
        transport_id: required_string(transport_id, "transport id"),
        external_id: required_string(external_id, "external conversation id")
      )
    end

    def inbound_message(conversation:, message_id:, actor:, text: "", attachments: [], reply_context: {}, idempotency_key:, metadata: {})
      unless conversation.is_a?(ConversationKey)
        raise ArgumentError, "conversation must be a Transport::ConversationKey"
      end
      unless actor.is_a?(Actor)
        raise ArgumentError, "actor must be a Transport::Actor"
      end

      InboundMessage.new(
        conversation: conversation,
        message_id: required_string(message_id, "message id"),
        actor: actor,
        text: text.to_s.freeze,
        attachments: frozen_copy(Array(attachments)),
        reply_context: frozen_copy(reply_context),
        idempotency_key: required_string(idempotency_key, "idempotency key"),
        metadata: frozen_copy(metadata)
      )
    end

    def turn_event(type:, session_id:, turn_id:, sequence:, payload: {})
      TurnEvent.new(
        type: required_string(type, "turn event type"),
        session_id: required_string(session_id, "session id"),
        turn_id: required_string(turn_id, "turn id"),
        sequence: Integer(sequence),
        payload: frozen_copy(payload)
      )
    end

    def interaction_request(id:, session_id:, turn_id:, kind:, prompt:, choices: [], expires_at: nil, metadata: {})
      InteractionRequest.new(
        id: required_string(id, "interaction id"),
        session_id: required_string(session_id, "session id"),
        turn_id: required_string(turn_id, "turn id"),
        kind: required_string(kind, "interaction kind"),
        prompt: required_string(prompt, "interaction prompt"),
        choices: frozen_copy(Array(choices)),
        expires_at: expires_at,
        metadata: frozen_copy(metadata)
      )
    end

    def execution_profile(
      id:,
      tool_mode: :all,
      allowed_tools: nil,
      disabled_tools: nil,
      plugin_commands: true,
      approval_mode: :default,
      memory: :default,
      attachments: true,
      workspace_mode: :session,
      prompt_context: nil
    )
      id = required_string(id, "execution profile id")
      tool_mode = tool_mode.to_sym
      approval_mode = approval_mode.to_sym
      memory = memory.to_sym
      workspace_mode = workspace_mode.to_sym
      raise ArgumentError, "unsupported tool mode: #{tool_mode}" unless TOOL_MODES.include?(tool_mode)
      raise ArgumentError, "unsupported approval mode: #{approval_mode}" unless APPROVAL_MODES.include?(approval_mode)
      raise ArgumentError, "unsupported memory mode: #{memory}" unless MEMORY_MODES.include?(memory)
      raise ArgumentError, "unsupported workspace mode: #{workspace_mode}" unless WORKSPACE_MODES.include?(workspace_mode)
      raise ArgumentError, "allowlist tool mode requires allowed_tools" if tool_mode == :allowlist && Array(allowed_tools).empty?
      raise ArgumentError, "none tool mode cannot define allowed_tools" if tool_mode == :none && allowed_tools
      raise ArgumentError, "allowed_tools and disabled_tools cannot both be set" if allowed_tools && disabled_tools

      ExecutionProfile.new(
        id: id,
        tool_mode: tool_mode,
        allowed_tools: frozen_symbols(allowed_tools),
        disabled_tools: frozen_symbols(disabled_tools),
        plugin_commands: !!plugin_commands,
        approval_mode: approval_mode,
        memory: memory,
        attachments: !!attachments,
        workspace_mode: workspace_mode,
        prompt_context: prompt_context.nil? ? nil : prompt_context.to_s.freeze
      )
    end

    def capabilities(inbound: [], outbound: [], streaming: :none, limits: {})
      streaming = streaming.to_sym
      raise ArgumentError, "unsupported streaming mode: #{streaming}" unless STREAMING_MODES.include?(streaming)

      Capabilities.new(
        inbound: frozen_symbols(inbound),
        outbound: frozen_symbols(outbound),
        streaming: streaming,
        limits: frozen_copy(limits)
      )
    end

    def required_string(value, name)
      value = value.to_s
      raise ArgumentError, "#{name} is required" if value.empty?

      value.freeze
    end
    private_class_method :required_string

    def optional_string(value)
      value.nil? ? nil : value.to_s.freeze
    end
    private_class_method :optional_string

    def frozen_symbols(values)
      Array(values).map { |value| value.to_sym }.uniq.freeze
    end
    private_class_method :frozen_symbols

    def frozen_copy(value)
      DeepCopy.freeze(DeepCopy.dup(value))
    end
    private_class_method :frozen_copy
  end
end

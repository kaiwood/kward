require "base64"
require "digest"
require "thread"
require_relative "../deep_copy"
require_relative "store"

module Kward
  module Transport
    # Adapts the existing session manager to the transport host contract.
    #
    # The adapter deliberately uses the manager's public session and turn
    # methods. It can be replaced by a frontend-neutral runtime gateway later
    # without changing transport plugins.
    class Gateway
      POLL_INTERVAL = 0.05
      TERMINAL_STATUSES = %w[completed canceled failed].freeze

      def initialize(session_manager:, transport_id:, storage: nil, poll_interval: POLL_INTERVAL)
        @session_manager = session_manager
        @transport_id = transport_id.to_s
        @storage = storage || Store.new(@transport_id)
        @poll_interval = poll_interval
        @subscriptions = []
        @interaction_subscribers = []
        @mutex = Mutex.new
        @session_manager.subscribe_events { |method, payload| handle_runtime_event(method, payload) } if @session_manager.respond_to?(:subscribe_events)
      end

      def resolve_transport_session(transport_id:, conversation:, actor:, workspace_root: nil, name: nil, execution_profile: nil)
        raise ArgumentError, "transport id does not match gateway" unless transport_id.to_s == @transport_id
        if conversation.respond_to?(:transport_id) && conversation.transport_id.to_s != @transport_id
          raise ArgumentError, "conversation transport does not match gateway"
        end

        binding_key = binding_key_for(conversation)
        binding = @storage.get(binding_key)
        session = if binding
                     resume_bound_session(binding, execution_profile: execution_profile)
                   else
                     @session_manager.create_session(workspace_root: workspace_root || Dir.pwd, name: name, **execution_profile_arguments(execution_profile))
                   end
        persist_binding(binding_key, session)
        session_handle(session)
      end

      def start_transport_turn(session_id:, input:, attachments: [], options: {}, streaming_behavior: nil, execution_profile: nil)
        payload = @session_manager.start_turn(
          session_id: session_id,
          input: input,
          attachments: normalize_attachments(attachments, execution_profile: execution_profile),
          options: profile_options(options, execution_profile),
          streaming_behavior: streaming_behavior,
          execution_profile: execution_profile
        )
        { id: payload.fetch(:id), session_id: payload.fetch(:sessionId) }
      end

      def transport_transcript(session_id:)
        @session_manager.transcript(session_id: session_id)
      end

      def transport_turn_events(turn_id:, after: nil)
        payload = @session_manager.turn_events(turn_id: turn_id, after_sequence: after.to_i)
        Array(payload[:events]).map { |event| normalize_event(event) }
      end

      def transport_turn_status(turn_id:)
        @session_manager.turn_status(turn_id: turn_id)
      end

      def cancel_transport_turn(turn_id:)
        @session_manager.cancel_turn(turn_id: turn_id)
      end

      def answer_transport_interaction(session_id:, request_id:, answer:)
        if answer == true || answer == false
          @session_manager.answer_tool_approval(
            session_id: session_id,
            approval_request_id: request_id,
            approved: answer
          )
        else
          answers = answer.is_a?(Array) ? answer : [{ question: request_id, answer: answer.to_s }]
          @session_manager.answer_question(
            session_id: session_id,
            question_request_id: request_id,
            answers: answers
          )
        end
      end

      def subscribe_transport_interactions(&block)
        raise ArgumentError, "interaction subscription requires a block" unless block

        @mutex.synchronize { @interaction_subscribers << block }
        block
      end

      def subscribe_transport_turn(turn_id:, after: nil)
        cursor = after.to_i
        thread = Thread.new do
          loop do
            events = transport_turn_events(turn_id: turn_id, after: cursor)
            events.each do |event|
              cursor = event.sequence
              yield event
            end
            status = transport_turn_status(turn_id: turn_id)
            break if TERMINAL_STATUSES.include?(status[:status].to_s)

            sleep @poll_interval
          end
        rescue StandardError
          nil
        end
        @mutex.synchronize { @subscriptions << thread }
        thread
      end

      def shutdown
        subscriptions = @mutex.synchronize do
          current = @subscriptions
          @subscriptions = []
          @interaction_subscribers = []
          current
        end
        subscriptions.each(&:kill)
        subscriptions.each(&:join)
        nil
      end

      private

      def resume_bound_session(binding, execution_profile: nil)
        @session_manager.resume_session(
          path: binding.fetch("path"),
          workspace_root: binding.fetch("workspace_root"),
          include_transcript: false,
          **execution_profile_arguments(execution_profile)
        )
      rescue StandardError
        @session_manager.create_session(workspace_root: binding.fetch("workspace_root"), **execution_profile_arguments(execution_profile))
      end

      def execution_profile_arguments(profile)
        profile ? { execution_profile: profile } : {}
      end

      def persist_binding(key, session)
        @storage.put(key, {
          "path" => session.fetch(:path),
          "workspace_root" => session.fetch(:workspaceRoot)
        })
      end

      def session_handle(session)
        Host::SessionHandle.new(
          id: session.fetch(:id),
          workspace_root: session.fetch(:workspaceRoot),
          name: session[:name]
        )
      end

      def binding_key_for(conversation)
        external_id = conversation.respond_to?(:external_id) ? conversation.external_id : conversation.to_s
        digest = Digest::SHA256.hexdigest("#{@transport_id}\0#{external_id}")
        "binding:#{digest}"
      end

      def handle_runtime_event(method, payload)
        request = case method
                  when "ui/question"
                    questions = Array(payload[:questions] || payload["questions"])
                    Transport.interaction_request(
                      id: payload[:questionRequestId] || payload["questionRequestId"],
                      session_id: payload[:sessionId] || payload["sessionId"],
                      turn_id: payload[:turnId] || payload["turnId"] || "unknown",
                      kind: :question,
                      prompt: questions.map { |question| question[:question] || question["question"] }.join("\\n"),
                      choices: questions
                    )
                  when "tool/approvalRequested"
                    Transport.interaction_request(
                      id: payload[:approvalRequestId] || payload["approvalRequestId"],
                      session_id: payload[:sessionId] || payload["sessionId"],
                      turn_id: payload[:turnId] || payload["turnId"] || "unknown",
                      kind: :tool_approval,
                      prompt: "Allow #{payload[:toolName] || payload["toolName"]}?",
                      choices: [{ id: "approve", label: "Approve" }, { id: "deny", label: "Deny" }],
                      metadata: { tool_call_id: payload[:toolCallId] || payload["toolCallId"], args: payload[:args] || payload["args"] }
                    )
                  end
        return unless request

        subscribers = @mutex.synchronize { @interaction_subscribers.dup }
        subscribers.each do |subscriber|
          begin
            subscriber.call(request)
          rescue StandardError
            nil
          end
        end
      end

      def profile_options(options, profile)
        return options unless profile

        options = options.dup
        case profile.tool_mode
        when :none
          options.delete("disabledTools")
          options.delete(:disabled_tools)
          options["allowedTools"] = []
        when :allowlist
          options.delete("disabledTools")
          options.delete(:disabled_tools)
          options["allowedTools"] = profile.allowed_tools
        end
        options["approvalMode"] = "none" if profile.approval_mode == :deny
        options["approvalMode"] = "ask" if profile.approval_mode == :ask
        options
      end

      def normalize_attachments(attachments, execution_profile: nil)
        if execution_profile && !execution_profile.attachments && !Array(attachments).empty?
          raise ArgumentError, "transport execution profile does not allow attachments"
        end

        Array(attachments).map do |attachment|
          raise ArgumentError, "transport attachment must be a Transport::Attachment" unless attachment.is_a?(Attachment)
          raise ArgumentError, "transport attachment URLs are not supported by the session gateway" if attachment.url

          {
            type: "image",
            data: Base64.strict_encode64(attachment.data),
            mimeType: attachment.mime_type,
            name: attachment.name
          }.compact
        end
      end

      def normalize_event(event)
        Transport.turn_event(
          type: event.fetch(:type),
          session_id: event.fetch(:sessionId),
          turn_id: event.fetch(:turnId),
          sequence: event.fetch(:sequence),
          payload: event.fetch(:payload, {})
        )
      end
    end
  end
end

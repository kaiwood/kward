# Namespace for the Kward CLI agent runtime.
module Kward
  # Adapts a session-backed agent to the tab runtime interface. Plugin tab
  # drivers implement the same small surface without becoming Kward sessions.
  class SessionTabDriver
    attr_reader :session, :agent

    def initialize(session:, agent:)
      @session = session
      @agent = agent
    end

    def messages
      agent.conversation.messages
    end

    def conversation
      agent.conversation
    end

    def submit(input, display_input:, cancellation:, steering: nil, &block)
      options = { cancellation: cancellation }
      options[:display_input] = display_input unless display_input.nil?
      options[:steering] = steering if steering
      agent.ask(input, **options, &block)
    end

    def descriptor
      { "kind" => "session", "session_path" => session.path }
    end

    def session?
      true
    end

    def supports_steering?
      true
    end

    def assistant_label
      nil
    end
  end

  # Represents a persisted plugin tab whose provider plugin is unavailable.
  # Its descriptor is retained so reinstalling the plugin restores the tab.
  class UnavailableTabDriver
    attr_reader :descriptor

    def initialize(descriptor:, message:)
      @descriptor = descriptor
      @message = message
    end

    def messages
      [{ role: "assistant", content: @message }]
    end

    def submit(*)
      raise @message
    end

    def session?
      false
    end

    def supports_steering?
      false
    end

    def assistant_label
      "Plugin"
    end
  end

  # Dependencies made available to a plugin tab factory. The host deliberately
  # exposes provider transport and frontend-neutral facts, not CLI internals or
  # workspace session state.
  class PluginTabHost
    attr_reader :client, :workspace_root

    def initialize(client:, workspace_root:)
      @client = client
      @workspace_root = workspace_root
    end
  end
end

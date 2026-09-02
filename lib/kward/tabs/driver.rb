require_relative "../config_files"
require_relative "../plugins/resources"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Adapts a session-backed agent to the tab runtime interface. Plugin tab
  # drivers implement the same small surface without becoming Kward sessions.
  class SessionTabDriver
    attr_reader :session, :agent, :worktree

    def initialize(session:, agent:, worktree: nil)
      @session = session
      @agent = agent
      @worktree = worktree
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
      descriptor = { "kind" => "session", "session_path" => session.path }
      descriptor["worktree"] = worktree.descriptor if worktree
      descriptor
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
      @resources = PluginResources.new(name: "Kward plugin tab", warning_sink: ConfigFiles.warning_sink).tap(&:activate!)
    end

    # Starts cooperative background work owned by this tab instance.
    def background(name: nil, cancellation: nil, &block)
      @resources.background(name: name, cancellation: cancellation, &block)
    end

    # Registers cleanup that runs when the tab instance closes.
    def on_cleanup(resource = nil, &block)
      @resources.on_cleanup(resource, &block)
    end

    alias manage on_cleanup

    # Cancels tab-owned work and invokes cleanup callbacks.
    # @api private
    def shutdown(timeout: PluginResources::DEFAULT_SHUTDOWN_TIMEOUT)
      @resources.shutdown(timeout: timeout)
      self
    end
  end
end

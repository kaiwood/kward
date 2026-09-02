require "digest"
require "logger"
require_relative "../config_files"
require_relative "../deep_copy"
require_relative "../plugins/chat_contract"
require_relative "../plugins/host"
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

  # Dependencies and instance-scoped services made available to a plugin chat
  # factory without exposing CLI or workspace-session internals.
  class PluginTabHost
    SURFACES = %i[local rpc transport shared].freeze

    class LogDevice
      def write(message)
        ConfigFiles.emit_warning(message.to_s.chomp)
      end

      def close
        nil
      end
    end
    private_constant :LogDevice

    attr_reader :client, :workspace_root, :plugin_id, :type_id, :surface, :scope_key,
      :capabilities, :config, :storage, :logger

    def initialize(client:, workspace_root:, plugin_host: nil, type_id: nil, surface: :local, scope_key: "default", capabilities: nil, config: nil, storage: nil, logger: nil, env: ENV)
      @client = client
      @workspace_root = workspace_root
      @plugin_id = plugin_host&.id
      @type_id = required_value(type_id || @plugin_id || "anonymous", "plugin chat type id").freeze
      @surface = normalize_surface(surface)
      @scope_key = required_value(scope_key, "plugin chat scope key").freeze
      @capabilities = capabilities || PluginChatCapabilities.legacy
      @config = freeze_config(config || plugin_host&.config || ConfigFiles.plugin_config(storage_owner_id))
      @storage = PluginScopedStore.new(storage || plugin_host&.storage || default_storage, storage_namespace)
      @logger = logger || plugin_host&.logger || default_logger
      @env = env
      @resources = PluginResources.new(name: "Kward plugin chat #{@type_id}", warning_sink: ConfigFiles.warning_sink).tap(&:activate!)
    end

    # Starts cooperative background work owned by this chat instance.
    def background(name: nil, cancellation: nil, &block)
      @resources.background(name: name, cancellation: cancellation, &block)
    end

    # Registers cleanup that runs when the chat instance closes.
    def on_cleanup(resource = nil, &block)
      @resources.on_cleanup(resource, &block)
    end

    alias manage on_cleanup

    # Reads a secret from private plugin config, an explicit environment
    # variable, or the plugin's conventional KWARD_PLUGIN_* variable.
    def secret(key, env: nil)
      key = required_value(key, "secret key")
      value = config[key]
      value = @env[env.to_s] if value.nil? && env
      value = @env[default_secret_env_name(key)] if value.nil?
      value.to_s unless value.nil?
    end

    # Cancels chat-owned work and invokes cleanup callbacks.
    # @api private
    def shutdown(timeout: PluginResources::DEFAULT_SHUTDOWN_TIMEOUT)
      @resources.shutdown(timeout: timeout)
      self
    end

    private

    def storage_owner_id
      plugin_id || type_id
    end

    def storage_namespace
      "plugin_chat:#{type_id}:#{scope_key}"
    end

    def default_storage
      safe_id = "chat.#{Digest::SHA256.hexdigest(storage_owner_id)[0, 24]}"
      PluginStore.new(safe_id)
    end

    def freeze_config(value)
      raise ArgumentError, "Kward plugin config for #{storage_owner_id} must be an object" unless value.is_a?(Hash)

      DeepCopy.freeze(DeepCopy.dup(value))
    end

    def normalize_surface(value)
      surface = value.to_sym
      raise ArgumentError, "Unknown plugin chat surface: #{value}" unless SURFACES.include?(surface)

      surface
    end

    def required_value(value, name)
      value = value.to_s
      raise ArgumentError, "#{name} is required" if value.empty?

      value
    end

    def default_secret_env_name(key)
      parts = [storage_owner_id, key].map { |part| part.gsub(/[^A-Za-z0-9]/, "_").upcase }
      "KWARD_PLUGIN_#{parts.join("_")}"
    end

    def default_logger
      Logger.new(LogDevice.new).tap { |logger| logger.progname = "Kward plugin chat #{type_id}" }
    end
  end
end

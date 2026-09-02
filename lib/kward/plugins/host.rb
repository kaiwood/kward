require "json"
require "logger"
require "thread"
require_relative "../config_files"
require_relative "../deep_copy"
require_relative "../private_file"
require_relative "resources"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Private JSON-backed key/value storage scoped to one stable plugin ID.
  class PluginStore
    KEY_PATTERN = /\A[A-Za-z0-9][A-Za-z0-9:._-]*\z/.freeze

    attr_reader :plugin_id

    def initialize(plugin_id, root: ConfigFiles.config_dir)
      @plugin_id = validate_key(plugin_id, "plugin id")
      @path = File.join(File.expand_path(root), "plugin_state", @plugin_id, "state.json")
      @mutex = Mutex.new
      @values = load_state
    end

    def get(key)
      key = validate_key(key, "storage key")
      @mutex.synchronize { copy(@values[key]) }
    end

    def put(key, value)
      key = validate_key(key, "storage key")
      @mutex.synchronize do
        @values[key] = copy(value)
        persist
      end
      value
    end

    def delete(key)
      key = validate_key(key, "storage key")
      @mutex.synchronize do
        present = @values.key?(key)
        value = @values.delete(key)
        persist if present
        copy(value)
      end
    end

    private

    def load_state
      return {} unless File.file?(@path)

      state = JSON.parse(File.read(@path))
      values = state.fetch("values", {})
      raise JSON::ParserError, "plugin state values must be a JSON object" unless values.is_a?(Hash)

      values
    rescue JSON::ParserError => e
      raise "Invalid plugin state #{@path}: #{e.message}"
    end

    def persist
      PrivateFile.write_json(@path, "values" => @values)
    end

    def validate_key(value, name)
      value = value.to_s
      raise ArgumentError, "#{name} is required" unless value.match?(KEY_PATTERN)

      value
    end

    def copy(value)
      return nil if value.nil?

      DeepCopy.dup(value)
    end
  end

  # Shared immutable metadata and managed services for one identified plugin.
  class PluginHost
    ID_PATTERN = /\A[A-Za-z0-9][A-Za-z0-9._-]*\z/.freeze

    class LogDevice
      def write(message)
        ConfigFiles.emit_warning(message.to_s.chomp)
      end

      def close
        nil
      end
    end
    private_constant :LogDevice

    attr_reader :id, :version, :api_version, :source_path, :config, :storage, :logger

    def initialize(id:, version:, api_version:, source_path: nil, config: nil, storage: nil, logger: nil, env: ENV, storage_root: ConfigFiles.config_dir, warning_sink: nil)
      @id = validate_id(id).freeze
      @version = validate_value(version, "plugin version").freeze
      @api_version = validate_value(api_version, "plugin API version").freeze
      @source_path = source_path&.to_s&.freeze
      @config = freeze_config(config.nil? ? configured_values : config)
      @storage = storage || PluginStore.new(@id, root: storage_root)
      @logger = logger || default_logger
      @env = env
      @resources = PluginResources.new(name: "Kward plugin #{id}", warning_sink: warning_sink)
    end

    # Starts cooperative background work owned by this plugin. The block may
    # accept a cancellation token and must stop cooperatively when cancelled.
    #
    # @return [PluginTask]
    def background(name: nil, cancellation: nil, &block)
      @resources.background(name: name, cancellation: cancellation, &block)
    end

    # Registers idempotent cleanup for a subscription or other plugin resource.
    # The returned disposable may be invoked early; otherwise Kward invokes it
    # during plugin reload or shutdown.
    #
    # @return [PluginDisposable]
    def on_cleanup(resource = nil, &block)
      @resources.on_cleanup(resource, &block)
    end

    alias manage on_cleanup

    # Activates managed runtime services after plugin loading completes.
    # @api private
    def activate!
      @resources.activate!
      self
    end

    # Cancels background work and invokes registered cleanup callbacks.
    # @api private
    def shutdown(timeout: PluginResources::DEFAULT_SHUTDOWN_TIMEOUT)
      @resources.shutdown(timeout: timeout)
      self
    end

    # Reads a secret from private plugin config, an explicit environment
    # variable, or the plugin's conventional KWARD_PLUGIN_* variable.
    def secret(key, env: nil)
      key = validate_value(key, "secret key")
      value = config[key]
      value = @env[env.to_s] if value.nil? && env
      value = @env[default_secret_env_name(key)] if value.nil?
      value.to_s unless value.nil?
    end

    # Returns public metadata suitable for diagnostics and capability reports.
    def to_h
      { id: id, version: version, api_version: api_version }.freeze
    end

    private

    def configured_values
      plugins = ConfigFiles.read_config.fetch("plugins", {})
      raise ArgumentError, "Kward plugin config must be an object" unless plugins.is_a?(Hash)

      values = plugins.fetch(@id, {})
      raise ArgumentError, "Kward plugin config for #{@id} must be an object" unless values.is_a?(Hash)

      values
    end

    def freeze_config(value)
      raise ArgumentError, "Kward plugin config for #{@id} must be an object" unless value.is_a?(Hash)

      DeepCopy.freeze(DeepCopy.dup(value))
    end

    def validate_id(value)
      value = value.to_s
      raise ArgumentError, "plugin id is invalid: #{value}" unless value.match?(ID_PATTERN)

      value
    end

    def validate_value(value, name)
      value = value.to_s
      raise ArgumentError, "#{name} is required" if value.empty?

      value
    end

    def default_secret_env_name(key)
      parts = [id, key].map { |part| part.gsub(/[^A-Za-z0-9]/, "_").upcase }
      "KWARD_PLUGIN_#{parts.join("_")}"
    end

    def default_logger
      Logger.new(LogDevice.new).tap { |logger| logger.progname = "Kward plugin #{id}" }
    end
  end
end

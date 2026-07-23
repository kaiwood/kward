require "fileutils"
require "json"
require "thread"
require "time"
require_relative "../config_files"
require_relative "../deep_copy"
require_relative "../private_file"

module Kward
  module Transport
    # Small private JSON store scoped to one transport plugin.
    class Store
      KEY_PATTERN = /\A[A-Za-z0-9][A-Za-z0-9:._-]*\z/.freeze
      DEFAULT_MAX_PROCESSED_KEYS = 10_000

      attr_reader :transport_id

      def initialize(transport_id, root: ConfigFiles.config_dir)
        @transport_id = validate_key(transport_id, "transport id")
        @path = File.join(File.expand_path(root), "transports", @transport_id, "state.json")
        @mutex = Mutex.new
        @values, @processed = load_state
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
          value = @values.delete(key)
          persist if value
          copy(value)
        end
      end

      # Claims an external event key. Returns false when the key was already
      # claimed, making duplicate webhook and polling deliveries harmless.
      def claim(key, max_keys: DEFAULT_MAX_PROCESSED_KEYS)
        key = validate_key(key, "idempotency key")
        max_keys = Integer(max_keys)
        raise ArgumentError, "max_keys must be positive" unless max_keys.positive?

        @mutex.synchronize do
          return false if @processed.key?(key)

          @processed[key] = Time.now.utc.iso8601
          @processed.shift while @processed.length > max_keys
          persist
          true
        end
      end

      private

      def load_state
        return [{}, {}] unless File.file?(@path)

        state = JSON.parse(File.read(@path))
        values = state.fetch("values", {})
        processed = state.fetch("processed", {})
        unless values.is_a?(Hash) && processed.is_a?(Hash)
          raise JSON::ParserError, "transport state must contain JSON objects"
        end

        [values, processed]
      rescue JSON::ParserError => e
        raise "Invalid transport state #{@path}: #{e.message}"
      end

      def persist
        directory = File.dirname(@path)
        FileUtils.mkdir_p(directory, mode: 0o700)
        temporary_path = "#{@path}.#{$$}.#{Thread.current.object_id}.tmp"
        PrivateFile.write_json(temporary_path, "values" => @values, "processed" => @processed)
        File.rename(temporary_path, @path)
        File.chmod(0o600, @path)
      ensure
        File.delete(temporary_path) if temporary_path && File.exist?(temporary_path)
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
  end
end

# Namespace for the Kward CLI agent runtime.
module Kward
  # Versioned capabilities declared by a plugin-owned chat type.
  class PluginChatCapabilities
    API_VERSION = 1
    ATTACHMENT_TYPES = %i[image].freeze
    KEYS = %i[attachments steering transcript_paging].freeze

    attr_reader :api_version, :attachments

    def self.build(api:, capabilities:)
      return legacy if api.nil? && capabilities.nil?
      raise ArgumentError, "Plugin chat api and capabilities are required together" if api.nil? || capabilities.nil?

      new(api_version: api, capabilities: capabilities, declared: true)
    end

    def self.legacy
      @legacy ||= new(
        api_version: nil,
        capabilities: { attachments: ATTACHMENT_TYPES, steering: nil, transcript_paging: nil },
        declared: false
      )
    end

    def initialize(api_version:, capabilities:, declared:)
      @declared = declared
      @api_version = normalize_api_version(api_version)
      values = normalize_capabilities(capabilities)
      @attachments = normalize_attachments(values.fetch(:attachments, [])).freeze
      @steering = normalize_boolean(values.fetch(:steering, false), :steering)
      @transcript_paging = normalize_boolean(values.fetch(:transcript_paging, false), :transcript_paging)
      freeze
    end

    def declared?
      @declared
    end

    def steering?
      @steering == true
    end

    def transcript_paging?
      @transcript_paging == true
    end

    def allows_attachment?(type)
      attachments.include?(type.to_sym)
    end

    def to_h
      return {} unless declared?

      {
        api_version: api_version,
        attachments: attachments.map(&:to_s).freeze,
        steering: steering?,
        transcript_paging: transcript_paging?
      }.freeze
    end

    def validate_driver!(driver)
      return driver unless declared?

      missing = %i[messages submit descriptor supports_steering? assistant_label].reject { |method| driver.respond_to?(method) }
      unless missing.empty?
        raise ArgumentError, "Plugin chat driver is missing required methods: #{missing.join(', ')}"
      end
      if driver.supports_steering? != steering?
        raise ArgumentError, "Plugin chat steering capability does not match driver.supports_steering?"
      end
      if transcript_paging? && !driver.respond_to?(:transcript_page)
        raise ArgumentError, "Plugin chat declares transcript paging but driver does not implement transcript_page"
      end

      driver
    end

    private

    def normalize_api_version(value)
      return nil unless @declared

      version = begin
        Integer(value)
      rescue ArgumentError, TypeError
        nil
      end
      unless version == API_VERSION
        raise ArgumentError, "Unsupported Kward plugin chat API #{value.inspect}; supported API: #{API_VERSION}"
      end

      version
    end

    def normalize_capabilities(capabilities)
      raise ArgumentError, "Plugin chat capabilities must be an object" unless capabilities.is_a?(Hash)

      values = capabilities.each_with_object({}) { |(key, value), result| result[key.to_sym] = value }
      unknown = values.keys - KEYS
      raise ArgumentError, "Unknown plugin chat capabilities: #{unknown.join(', ')}" unless unknown.empty?

      values
    end

    def normalize_attachments(values)
      attachments = Array(values).map(&:to_sym)
      unknown = attachments - ATTACHMENT_TYPES
      raise ArgumentError, "Unsupported plugin chat attachment types: #{unknown.join(', ')}" unless unknown.empty?

      attachments.uniq
    end

    def normalize_boolean(value, name)
      return value if value == true || value == false || value.nil?

      raise ArgumentError, "Plugin chat #{name} capability must be true or false"
    end
  end
end

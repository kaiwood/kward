require "uri"

# Namespace for Kward model-provider support.
module Kward
  # Validated Azure OpenAI endpoint and deployment settings.
  class AzureOpenAIConfig
    DEPLOYMENT_PATTERN = /\A[a-zA-Z0-9._-]+\z/
    API_VERSION_PATTERN = /\A[a-zA-Z0-9._-]+\z/

    def initialize(endpoint:, deployment:, api_version:)
      @endpoint = normalize_endpoint(endpoint)
      @deployment = validate_value(deployment, "deployment name", DEPLOYMENT_PATTERN)
      @api_version = validate_value(api_version, "API version", API_VERSION_PATTERN)
    end

    attr_reader :endpoint, :deployment, :api_version

    def to_config
      {
        "azure_openai_endpoint" => endpoint,
        "azure_openai_model" => deployment,
        "azure_openai_api_version" => api_version
      }
    end

    private

    def normalize_endpoint(value)
      text = value.to_s.strip
      raise ArgumentError, "Azure OpenAI endpoint must be a non-empty HTTPS URL" if text.empty?

      uri = URI.parse(text)
      unless uri.is_a?(URI::HTTPS) && !uri.host.to_s.empty? && uri.user.nil? && uri.password.nil? && uri.query.nil? && uri.fragment.nil?
        raise ArgumentError, "Azure OpenAI endpoint must be an HTTPS URL without credentials, query, or fragment"
      end

      uri.to_s.sub(%r{/+\z}, "")
    rescue URI::InvalidURIError
      raise ArgumentError, "Azure OpenAI endpoint must be a valid HTTPS URL"
    end

    def validate_value(value, label, pattern)
      text = value.to_s.strip
      raise ArgumentError, "Azure OpenAI #{label} must be a non-empty string" if text.empty?
      raise ArgumentError, "Azure OpenAI #{label} contains invalid characters" unless text.match?(pattern)

      text
    end
  end
end

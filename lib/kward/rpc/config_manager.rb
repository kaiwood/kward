require "fileutils"
require "json"
require_relative "../openai_oauth"
require_relative "redactor"

module Kward
  module RPC
    class ConfigManager
      def initialize(config_path: OpenAIOAuth.default_config_path)
        @config_path = File.expand_path(config_path)
      end

      attr_reader :config_path

      def read(redacted: true)
        config = load_config
        redacted ? Redactor.redact(config) : config
      end

      def update(values)
        raise "Config values must be an object" unless values.is_a?(Hash)

        config = load_config
        values.each { |key, value| config[key.to_s] = value }
        write_config(config)
        Redactor.redact(config)
      end

      def set_model(model, provider: nil)
        model = model.to_s.strip
        raise "Model must be a non-empty string" if model.empty?

        key = provider.to_s == "OpenRouter" ? "openrouter_model" : "openai_model"
        update(key => model)
      end

      def set_reasoning_effort(effort)
        effort = effort.to_s.strip
        raise "Reasoning effort must be a non-empty string" if effort.empty?

        update("openai_reasoning_effort" => effort)
      end

      def set_api_key(provider_id, api_key)
        provider_id = provider_id.to_s
        api_key = api_key.to_s.strip
        raise "API key must be a non-empty string" if api_key.empty?
        raise "Unsupported API key provider: #{provider_id}" unless provider_id == "openrouter"

        update("openrouter_api_key" => api_key)
      end

      def delete_key(key)
        config = load_config
        existed = config.key?(key.to_s)
        config.delete(key.to_s)
        write_config(config) if existed
        existed
      end

      private

      def load_config
        return {} unless File.exist?(@config_path)

        JSON.parse(File.read(@config_path))
      rescue JSON::ParserError
        raise "Invalid Kward config JSON: #{@config_path}"
      end

      def write_config(config)
        FileUtils.mkdir_p(File.dirname(@config_path), mode: 0o700)
        File.open(@config_path, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |file|
          file.write(JSON.pretty_generate(config))
          file.write("\n")
        end
        File.chmod(0o600, @config_path)
      end
    end
  end
end

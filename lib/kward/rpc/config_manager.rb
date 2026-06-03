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

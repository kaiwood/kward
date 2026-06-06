require "fileutils"
require "json"
require "time"
require_relative "config_files"
require_relative "rpc/redactor"

module Kward
  class TelemetryLogger
    CATEGORIES = %w[tokens performance tools errors].freeze
    ENV_KEYS = {
      "enabled" => "KWARD_LOGGING",
      "tokens" => "KWARD_LOGGING_TOKENS",
      "performance" => "KWARD_LOGGING_PERFORMANCE",
      "tools" => "KWARD_LOGGING_TOOLS",
      "errors" => "KWARD_LOGGING_ERRORS"
    }.freeze
    DEFAULT_MAX_BYTES = 10 * 1024 * 1024

    def initialize(config_path: ConfigFiles.config_path, log_dir: nil, max_bytes: DEFAULT_MAX_BYTES, clock: Time, monotonic_clock: Process, error_output: $stderr)
      @config_path = config_path
      @log_dir = log_dir
      @max_bytes = max_bytes.to_i.positive? ? max_bytes.to_i : DEFAULT_MAX_BYTES
      @clock = clock
      @monotonic_clock = monotonic_clock
      @error_output = error_output
      @mutex = Mutex.new
      @warned = false
    end

    def enabled?(category)
      settings = current_settings
      settings["enabled"] && settings[category.to_s]
    end

    def log(category, event, payload = {})
      category = category.to_s
      return false unless enabled?(category)

      record = sanitize_record(payload).merge(
        "timestamp" => @clock.now.utc.iso8601(3),
        "category" => category,
        "event" => event.to_s
      )
      write_record(record)
      true
    rescue StandardError => e
      warn_once(e)
      false
    end

    def duration_ms(started_at)
      ((monotonic_now - started_at.to_f) * 1000).round(1)
    end

    def monotonic_now
      @monotonic_clock.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def self.error_payload(error)
      payload = { "error_class" => error.class.name }
      if error.respond_to?(:provider) && error.respond_to?(:code)
        payload["provider"] = error.provider
        payload["error_code"] = error.code
        payload["error_message"] = "#{error.provider} request failed: #{error.code}"
      else
        payload["error_message"] = RPC::Redactor.redact_string(error.message.to_s)[0, 500]
      end
      payload
    end

    private

    def current_settings
      values = config_settings
      ENV_KEYS.each do |key, env_key|
        env_value = parse_bool(ENV[env_key])
        values[key] = env_value unless env_value.nil?
      end
      values
    end

    def config_settings
      logging = ConfigFiles.read_config(@config_path)["logging"]
      logging = {} unless logging.is_a?(Hash)
      {
        "enabled" => truthy?(logging["enabled"]),
        "tokens" => truthy?(logging["tokens"]),
        "performance" => truthy?(logging["performance"]),
        "tools" => truthy?(logging["tools"]),
        "errors" => truthy?(logging["errors"])
      }
    rescue StandardError
      CATEGORIES.each_with_object({ "enabled" => false }) { |category, result| result[category] = false }
    end

    def truthy?(value)
      value == true
    end

    def parse_bool(value)
      return nil if value.nil?

      text = value.to_s.strip.downcase
      return true if %w[1 true yes on].include?(text)
      return false if %w[0 false no off].include?(text)

      nil
    end

    def sanitize_record(payload)
      sanitized = redact(payload || {})
      sanitized.is_a?(Hash) ? sanitized : { "value" => sanitized }
    end

    def redact(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, item), result|
          result[key] = secret_key?(key) ? "[REDACTED]" : redact(item)
        end
      when Array
        value.map { |item| redact(item) }
      when String
        RPC::Redactor.redact_string(value)
      else
        value
      end
    end

    def secret_key?(key)
      text = key.to_s
      return false if token_count_key?(text)

      RPC::Redactor.secret_key?(text)
    end

    def token_count_key?(key)
      key.match?(/\A(?:input|output|cache_read|cache_write|total)_tokens\z/) || key == "estimated"
    end

    def write_record(record)
      @mutex.synchronize do
        dir = log_dir
        FileUtils.mkdir_p(dir, mode: 0o700)
        path = current_log_path(dir)
        File.open(path, File::WRONLY | File::CREAT | File::APPEND, 0o600) do |file|
          file.write(JSON.generate(record))
          file.write("\n")
        end
        File.chmod(0o600, path)
      end
    end

    def log_dir
      @log_dir || File.join(File.dirname(File.expand_path(@config_path)), "logs")
    end

    def current_log_path(dir)
      base = File.join(dir, "#{@clock.now.utc.strftime("%Y-%m-%d")}.jsonl")
      return base if writable_log_path?(base)

      index = 1
      loop do
        path = base.sub(/\.jsonl\z/, "-#{index}.jsonl")
        return path if writable_log_path?(path)

        index += 1
      end
    end

    def writable_log_path?(path)
      !File.exist?(path) || File.size(path) < @max_bytes
    end

    def warn_once(error)
      return if @warned

      @warned = true
      @error_output&.puts("Warning: telemetry logging failed: #{error.message}")
    rescue StandardError
      nil
    end
  end
end

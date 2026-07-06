require "fileutils"
require "json"
require "time"
require_relative "../config_files"
require_relative "../rpc/redactor"

# Namespace for the Kward CLI agent runtime.
module Kward
  module Hooks
    # Append-only JSONL audit log for lifecycle hook activity.
    class AuditLog
      DEFAULT_MAX_BYTES = 10 * 1024 * 1024

      def initialize(path: nil, config_path: ConfigFiles.config_path, max_bytes: DEFAULT_MAX_BYTES, clock: Time, monotonic_clock: Process, error_output: $stderr)
        @path = path
        @config_path = config_path
        @max_bytes = max_bytes.to_i.positive? ? max_bytes.to_i : DEFAULT_MAX_BYTES
        @clock = clock
        @monotonic_clock = monotonic_clock
        @error_output = error_output
        @mutex = Mutex.new
        @warned = false
      end

      def monotonic_now
        @monotonic_clock.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def duration_ms(started_at)
        ((monotonic_now - started_at.to_f) * 1000).round(1)
      end

      def log_handler(event:, handler:, decision:, duration_ms: nil)
        write_record(
          "kind" => "handler",
          "event_id" => event.id,
          "event" => event.name,
          "phase" => event.phase,
          "hook_id" => handler.id,
          "source" => handler.source,
          "decision" => decision.decision,
          "message" => redact_string(decision.message),
          "duration_ms" => duration_ms,
          "payload_keys" => safe_keys(event.payload),
          "modified_keys" => decision.modify? ? safe_keys(decision.payload) : []
        )
      end

      def log_result(event:, result:)
        write_record(
          "kind" => "result",
          "event_id" => event.id,
          "event" => event.name,
          "phase" => event.phase,
          "decision" => result.decision.decision,
          "message" => redact_string(result.decision.message),
          "handler_count" => result.decisions.length,
          "warnings" => result.warnings.map { |warning| redact_string(warning) },
          "messages" => result.messages.map { |message| redact_string(message) },
          "payload_keys" => safe_keys(result.payload)
        )
      end

      private

      def write_record(payload)
        @mutex.synchronize do
          path = current_path
          FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
          File.open(path, File::WRONLY | File::CREAT | File::APPEND, 0o600) do |file|
            file.write(JSON.generate(payload.compact.merge("timestamp" => @clock.now.utc.iso8601(3))))
            file.write("\n")
          end
          File.chmod(0o600, path)
        end
        true
      rescue StandardError => e
        warn_once(e)
        false
      end

      def current_path
        explicit_path = @path || File.join(File.dirname(File.expand_path(@config_path)), "logs", "hooks.jsonl")
        return explicit_path if writable_log_path?(explicit_path)

        index = 1
        loop do
          path = explicit_path.sub(/\.jsonl\z/, "-#{index}.jsonl")
          return path if writable_log_path?(path)

          index += 1
        end
      end

      def writable_log_path?(path)
        !File.exist?(path) || File.size(path) < @max_bytes
      end

      def safe_keys(value)
        return [] unless value.is_a?(Hash)

        value.keys.map(&:to_s).sort
      end

      def redact_string(value)
        return nil if value.nil?

        RPC::Redactor.redact_string(value.to_s)[0, 500]
      end

      def warn_once(error)
        return if @warned

        @warned = true
        @error_output&.puts("Warning: hook audit logging failed: #{error.message}")
      rescue StandardError
        nil
      end
    end
  end
end

require_relative "sequences"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Terminal capability detection for inline image protocols.
  module TerminalImageSupport
    KITTY = :kitty
    ITERM2 = :iterm2
    PROBE_TIMEOUT = 0.3
    KITTY_PROBE = "#{TerminalSequences.kitty_query}\e[c".freeze
    KITTY_OK_RESPONSE = "\e_Gi=31;OK\e\\".freeze
    DA1_RESPONSE_PATTERN = /\e\[\?[0-9;]*c/.freeze

    module_function

    def detect(env: ENV, input: nil, output: nil, timeout: PROBE_TIMEOUT, probe_result: :auto)
      return static_protocol(env) if input.nil? && output.nil? && probe_result == :auto
      return nil unless tty?(input) && tty?(output)

      probe_result = probe_kitty(input, output, env: env, timeout: timeout) if probe_result == :auto
      return KITTY if probe_result == true

      fallback = static_protocol(env)
      return fallback if probe_result.nil? || fallback

      nil
    end

    def static_protocol(env)
      return KITTY if kitty_hint?(env)
      return ITERM2 if iterm2_hint?(env)

      nil
    end

    def probe_kitty(input, output, env: ENV, timeout: PROBE_TIMEOUT)
      return nil unless tty?(input) && tty?(output)
      return nil unless input.respond_to?(:raw)
      return nil unless output.respond_to?(:write) && output.respond_to?(:flush)

      query = env["TMUX"].to_s.empty? ? KITTY_PROBE : TerminalSequences.tmux_passthrough(KITTY_PROBE)
      input.raw do
        output.write(query)
        output.flush
        read_probe_response(input, timeout: timeout)
      end
    rescue StandardError
      nil
    end

    def read_probe_response(input, timeout: PROBE_TIMEOUT)
      buffer = +""
      deadline = monotonic_now + timeout.to_f
      loop do
        break if da1_response?(buffer)

        remaining = deadline - monotonic_now
        break if remaining <= 0

        ready = IO.select([input], nil, nil, remaining)
        break unless ready

        chunk = input.read_nonblock(256, exception: false)
        break if chunk == :wait_readable || chunk.nil? || chunk.empty?

        buffer << chunk
      end

      kitty_probe_success?(buffer)
    rescue IOError, SystemCallError
      false
    end

    def kitty_probe_success?(response)
      da1_response?(response) && response.to_s.include?(KITTY_OK_RESPONSE)
    end

    def da1_response?(response)
      response.to_s.match?(DA1_RESPONSE_PATTERN)
    end

    def kitty_hint?(env)
      value = normalized_environment(env)
      return true if value["KITTY_WINDOW_ID"] && !value["KITTY_WINDOW_ID"].empty?

      program = value.fetch("TERM_PROGRAM", "")
      term = value.fetch("TERM", "")
      program == "kitty" || program == "ghostty" || term.include?("kitty") || term.include?("ghostty")
    end

    def iterm2_hint?(env)
      value = normalized_environment(env)
      program = value.fetch("TERM_PROGRAM", "")
      return true if program == "iterm.app" || program == "wezterm"
      return true if value.fetch("TERM_FEATURES", "").include?("f")

      value["WEZTERM_PANE"] && !value["WEZTERM_PANE"].empty?
    end

    def normalized_environment(env)
      env.to_h.each_with_object({}) do |(key, value), normalized|
        normalized[key.to_s] = value.to_s.strip.downcase
      end
    end

    def tty?(io)
      io.respond_to?(:tty?) && io.tty?
    rescue IOError, SystemCallError
      false
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end

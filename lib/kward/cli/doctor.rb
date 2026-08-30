# Namespace for the Kward CLI agent runtime.
module Kward
  # Command-line frontend that coordinates terminal interaction, sessions, tools, and model turns.
  class CLI
    # Environment and configuration diagnostics for the `doctor` command.
    module Doctor
      private

      # Writes the doctor output for the terminal CLI flow.
      def print_doctor
        checks = doctor_checks
        core_checks, optional_checks = checks.partition { |check| !check[:optional] }
        lines = [colored("Kward Doctor", :green, :bold), "", colored("Core checks", :blue, :bold)]
        lines.concat(doctor_check_lines(core_checks))
        if optional_checks.any?
          lines << ""
          lines << colored("Optional", :blue, :bold)
          lines.concat(doctor_check_lines(optional_checks))
        end
        lines << ""
        lines << doctor_summary(checks)
        @prompt.say lines.join("\n")
        checks.none? { |check| check.fetch(:status) == :error && !check[:optional] }
      end

      def doctor_check_lines(checks)
        checks.map { |check| "#{doctor_mark(check.fetch(:status))} #{check.fetch(:label)}: #{check.fetch(:message)}" }
      end

      def doctor_summary(checks)
        errors = checks.count { |check| check.fetch(:status) == :error && !check[:optional] }
        warnings = checks.count { |check| check.fetch(:status) == :warning && !check[:optional] }
        return "Kward needs attention: #{errors} core check#{errors == 1 ? "" : "s"} failed." if errors.positive?
        return "Kward is ready with #{warnings} warning#{warnings == 1 ? "" : "s"}." if warnings.positive?

        "Kward is ready."
      end

      def doctor_checks
        config_result = safely_read_config
        config = config_result.is_a?(Hash) ? config_result : {}
        [
          doctor_config_check,
          doctor_config_json_check(config_result),
          doctor_directory_check("Config directory", ConfigFiles.config_dir),
          doctor_directory_check("Session directory", SessionStore.new(cwd: current_workspace_root).session_dir, create: true),
          doctor_workspace_check,
          doctor_model_check,
          doctor_local_endpoint_check(config),
          doctor_auth_check(config),
          doctor_pan_check(config_result),
          { status: :ok, label: "Color", message: @color_enabled ? "enabled" : "disabled" }
        ]
      end

      def safely_read_config
        ConfigFiles.read_config
      rescue ConfigFiles::ConfigError => e
        e
      rescue StandardError => e
        e
      end

      def doctor_config_check
        path = ConfigFiles.config_path
        if File.exist?(path)
          readable = File.readable?(path)
          return { status: readable ? :ok : :error, label: "Config", message: readable ? path : "not readable: #{path}" }
        end

        { status: :warning, label: "Config", message: "not found: #{path}" }
      end

      def doctor_config_json_check(config_result)
        return { status: :ok, label: "Config JSON", message: "valid" } if config_result.is_a?(Hash)
        if config_result.is_a?(ConfigFiles::ConfigError)
          return { status: :error, label: "Config JSON", message: "invalid: #{config_result.detail}" }
        end

        { status: :error, label: "Config JSON", message: "unreadable: #{config_result.message}" }
      end

      def doctor_directory_check(label, path, create: false)
        FileUtils.mkdir_p(path, mode: 0o700) if create
        if Dir.exist?(path) && File.writable?(path)
          { status: :ok, label: label, message: "writable: #{path}" }
        elsif Dir.exist?(path)
          { status: :error, label: label, message: "not writable: #{path}" }
        else
          { status: :error, label: label, message: "missing: #{path}" }
        end
      rescue StandardError => e
        { status: :error, label: label, message: e.message }
      end

      def doctor_workspace_check
        root = current_workspace_root
        return { status: :ok, label: "Workspace", message: root } if Dir.exist?(root) && File.directory?(root)

        { status: :error, label: "Workspace", message: "not a directory: #{root}" }
      end

      def doctor_model_check
        provider = @client.current_provider if @client.respond_to?(:current_provider)
        model = @client.current_model if @client.respond_to?(:current_model)
        parts = [provider, model].compact.map(&:to_s).reject(&:empty?)
        return { status: :ok, label: "Model", message: parts.join(" / ") } if parts.any?

        { status: :warning, label: "Model", message: "not configured" }
      rescue StandardError => e
        { status: :warning, label: "Model", message: e.message }
      end

      def doctor_local_endpoint_check(config)
        provider = ENV["KWARD_PROVIDER"].to_s.strip
        provider = config["provider"].to_s.strip if provider.empty?
        return { status: :ok, label: "Local endpoint", message: "not selected" } unless provider.casecmp?("local")

        backend = ENV["KWARD_LOCAL_BACKEND"].to_s.strip
        backend = config["local_backend"].to_s.strip if backend.empty?
        defaults = Kward::Client::LOCAL_BASE_URLS
        url = ENV["KWARD_LOCAL_BASE_URL"].to_s.strip
        url = config["local_base_url"].to_s.strip if url.empty?
        url = defaults.fetch(backend.empty? ? "ollama" : backend, defaults.fetch("ollama")) if url.empty?
        uri = URI.parse(url)
        loopback = ["127.0.0.1", "::1", "localhost"].include?(uri.host)
        { status: loopback ? :ok : :warning, label: "Local endpoint", message: "#{url}#{loopback ? " (loopback)" : " (non-loopback)"}" }
      rescue URI::InvalidURIError
        { status: :error, label: "Local endpoint", message: "invalid URL: #{url}" }
      end

      def doctor_auth_check(_config)
        local_provider = @client.respond_to?(:current_provider) && @client.current_provider == "Local"
        configured = auth_credentials.select { |credential| credential.fetch(:configured) }.map { |credential| credential.fetch(:label) }
        configured << "Local endpoint (no authentication required)" if local_provider
        return { status: :ok, label: "Auth", message: configured.join(", ") } if configured.any?

        { status: :warning, label: "Auth", message: "no saved credentials found; run `kward login`" }
      rescue ConfigFiles::ConfigError
        { status: :warning, label: "Auth", message: "skipped because config is invalid" }
      end

      def doctor_pan_check(config_result)
        return { status: :optional, label: "Pan mode", message: "skipped because config is invalid", optional: true } if config_result.is_a?(ConfigFiles::ConfigError)

        pan = config_result.to_h["pan_mode"] || {}
        environment_password = ENV["KWARD_PAN_PASSWORD"].to_s
        password = environment_password.empty? ? pan["password"].to_s : environment_password
        if !pan["username"].to_s.empty? && !password.empty?
          source = environment_password.empty? ? "config" : "environment"
          { status: :ok, label: "Pan mode", message: "credentials configured (password from #{source})", optional: true }
        else
          { status: :optional, label: "Pan mode", message: "not configured", optional: true }
        end
      end

      def doctor_mark(status)
        case status
        when :ok
          colored("✓", :green, :bold)
        when :warning
          colored("!", :yellow, :bold)
        when :optional
          colored("•", :gray, :bold)
        else
          colored("✗", :red, :bold)
        end
      end

    end
  end
end

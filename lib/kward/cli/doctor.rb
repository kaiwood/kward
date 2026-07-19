# Namespace for the Kward CLI agent runtime.
module Kward
  # Command-line frontend that coordinates terminal interaction, sessions, tools, and model turns.
  class CLI
    # Environment and configuration diagnostics for the `doctor` command.
    module Doctor
      private

      # Writes the doctor output for the terminal CLI flow.
      def print_doctor
        lines = ["#{colored("Kward Doctor", :green, :bold)}", ""]
        doctor_checks.each do |check|
          lines << "#{doctor_mark(check.fetch(:status))} #{check.fetch(:label)}: #{check.fetch(:message)}"
        end
        @prompt.say lines.join("\n")
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

      def doctor_auth_check(config)
        openai_auth = OpenAIOAuth.default_auth_path
        github_auth = GithubOAuth.default_auth_path
        has_openrouter = !config.to_h["openrouter_api_key"].to_s.empty? || !ENV["OPENROUTER_API_KEY"].to_s.empty?
        local_provider = @client.respond_to?(:current_provider) && @client.current_provider == "Local"
        paths = []
        paths << "OpenAI OAuth" if File.exist?(openai_auth)
        paths << "GitHub OAuth" if File.exist?(github_auth)
        paths << "OpenRouter API key" if has_openrouter
        paths << "Local endpoint (no authentication required)" if local_provider
        return { status: :ok, label: "Auth", message: paths.join(", ") } if paths.any?

        { status: :warning, label: "Auth", message: "no saved credentials found; run `kward login`" }
      end

      def doctor_pan_check(config_result)
        return { status: :warning, label: "Pan mode", message: "skipped because config is invalid" } if config_result.is_a?(ConfigFiles::ConfigError)

        pan = config_result.to_h["pan_mode"] || {}
        if !pan["username"].to_s.empty? && !pan["password"].to_s.empty?
          { status: :ok, label: "Pan mode", message: "credentials configured" }
        else
          { status: :warning, label: "Pan mode", message: "username/password not configured" }
        end
      end

      def doctor_mark(status)
        case status
        when :ok
          colored("✓", :green, :bold)
        when :warning
          colored("!", :yellow, :bold)
        else
          colored("✗", :red, :bold)
        end
      end

    end
  end
end

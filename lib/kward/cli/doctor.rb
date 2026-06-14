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
        config = safely_read_config
        [
          doctor_config_check,
          doctor_config_json_check(config),
          doctor_directory_check("Config directory", ConfigFiles.config_dir),
          doctor_directory_check("Session directory", SessionStore.new(cwd: current_workspace_root).session_dir, create: true),
          doctor_workspace_check,
          doctor_model_check,
          doctor_auth_check(config),
          doctor_pan_check(config),
          { status: :ok, label: "Color", message: @color_enabled ? "enabled" : "disabled" }
        ]
      end

      def safely_read_config
        ConfigFiles.read_config
      rescue StandardError
        nil
      end

      def doctor_config_check
        path = ConfigFiles.config_path
        if File.exist?(path)
          readable = File.readable?(path)
          return { status: readable ? :ok : :error, label: "Config", message: readable ? path : "not readable: #{path}" }
        end

        { status: :warning, label: "Config", message: "not found: #{path}" }
      end

      def doctor_config_json_check(config)
        return { status: :error, label: "Config JSON", message: "invalid or unreadable" } unless config.is_a?(Hash)

        { status: :ok, label: "Config JSON", message: "valid" }
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

      def doctor_auth_check(config)
        openai_auth = OpenAIOAuth.default_auth_path
        github_auth = GithubOAuth.default_auth_path
        has_openrouter = !config.to_h["openrouter_api_key"].to_s.empty? || !ENV["OPENROUTER_API_KEY"].to_s.empty?
        paths = []
        paths << "OpenAI OAuth" if File.exist?(openai_auth)
        paths << "GitHub OAuth" if File.exist?(github_auth)
        paths << "OpenRouter API key" if has_openrouter
        return { status: :ok, label: "Auth", message: paths.join(", ") } if paths.any?

        { status: :warning, label: "Auth", message: "no saved credentials found; run `kward login`" }
      end

      def doctor_pan_check(config)
        pan = config.to_h["pan_mode"] || {}
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

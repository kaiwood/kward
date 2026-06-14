module Kward
  class CLI
    module AuthCommands
      def handle_auth_command(arguments)
        if help_option_arguments?(arguments)
          print_command_help("auth")
          return
        end

        case arguments
        when ["status"]
          print_auth_status
        when ["logout"]
          logout_auth
        else
          raise ArgumentError, command_usage("auth")
        end
      end

      def print_auth_status
        config = safely_read_config.to_h
        lines = ["#{colored("Auth Status", :green, :bold)}", ""]
        lines << auth_status_line("OpenAI OAuth", File.exist?(OpenAIOAuth.default_auth_path), OpenAIOAuth.default_auth_path)
        lines << auth_status_line("GitHub OAuth", File.exist?(GithubOAuth.default_auth_path), GithubOAuth.default_auth_path)
        lines << auth_status_line("OpenRouter API key", !config["openrouter_api_key"].to_s.empty? || !ENV["OPENROUTER_API_KEY"].to_s.empty?, ConfigFiles.config_path)
        @prompt.say lines.join("\n")
      end

      def auth_status_line(label, configured, location)
        status = configured ? :ok : :warning
        message = configured ? "configured" : "not configured"
        "#{doctor_mark(status)} #{label}: #{message} (#{location})"
      end

      def logout_auth
        removed = []
        [OpenAIOAuth.default_auth_path, GithubOAuth.default_auth_path].each do |path|
          next unless File.exist?(path)

          File.delete(path)
          removed << path
        end
        removed << "OpenRouter API key" if OpenRouterAPIKey.new.logout

        if removed.empty?
          @prompt.say "No saved credentials found."
        else
          @prompt.say "Removed #{removed.length} saved credential#{removed.length == 1 ? "" : "s"}."
        end
      end

      def login(provider: nil, oauth: nil)
        provider = provider.to_s.downcase
        if provider == "openrouter"
          auth = oauth || OpenRouterAPIKey.new
          path = auth.login(prompt: @prompt)
          @prompt.say("#{colored("Saved", :green, :bold)} OpenRouter API key to #{path}")
          return
        end

        oauth ||= provider == "github" ? GithubOAuth.new : OpenAIOAuth.new
        path = oauth.login(prompt: @prompt)
        name = provider == "github" ? "GitHub" : "OpenAI"
        @prompt.say("#{colored("Saved", :green, :bold)} #{name} OAuth login to #{path}")
      end

    end
  end
end

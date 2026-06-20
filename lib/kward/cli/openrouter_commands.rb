# Namespace for the Kward CLI agent runtime.
module Kward
  # Command-line frontend that coordinates terminal interaction, sessions, tools, and model turns.
  class CLI
    # OpenRouter cache management commands for the terminal CLI flow.
    module OpenRouterCommands
      private

      def handle_openrouter_command(arguments)
        case arguments
        when ["refresh"], ["--refresh"]
          refresh_openrouter_models
        when ["list"], ["--list"]
          list_openrouter_models
        else
          raise ArgumentError, command_usage("openrouter")
        end
      end

      def refresh_openrouter_models
        cache = OpenRouterModelCache.new(api_key: configured_openrouter_api_key, path: openrouter_models_cache_path)
        data = cache.refresh
        count = Array(data["models"]).length
        @client.reload_config if @client.respond_to?(:reload_config)
        @prompt.say("Refreshed #{count} OpenRouter text model#{count == 1 ? "" : "s"} for this key.")
        @prompt.say("Cached at: #{cache.path}")
      rescue StandardError => e
        warn e.message
        exit 1
      end

      def list_openrouter_models
        cache = OpenRouterModelCache.new(api_key: configured_openrouter_api_key, path: openrouter_models_cache_path)
        data = cache.read
        unless data
          @prompt.say("No OpenRouter model cache found. Run `kward openrouter refresh` first.")
          return
        end

        models = Array(data["models"])
        lines = ["OpenRouter models cached at #{data["refreshed_at"]}:"]
        lines.concat(models.map { |model| model["id"].to_s }.reject(&:empty?))
        @prompt.say(lines.join("\n"))
      end

      def configured_openrouter_api_key
        ENV["OPENROUTER_API_KEY"].to_s.empty? ? ConfigFiles.config_value(ConfigFiles.read_config, "openrouter_api_key").to_s : ENV["OPENROUTER_API_KEY"].to_s
      end

      def openrouter_models_cache_path
        File.join(File.dirname(ConfigFiles.config_path), "cache", "openrouter_models.json")
      end
    end
  end
end

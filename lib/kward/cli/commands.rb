# Namespace for the Kward CLI agent runtime.
module Kward
  # Command-line frontend that coordinates terminal interaction, sessions, tools, and model turns.
  class CLI
    # Top-level command help, option parsing, and command dispatch helpers mixed into the CLI frontend.
    module Commands
      private

      def help_command?
        ["help", "--help", "-h"].include?(@argv.first) && @argv.length <= 2
      end

      def version_command?
        ["version", "--version", "-v"].include?(@argv.first) && @argv.length == 1
      end

      def help_option_arguments?(arguments)
        arguments.length == 1 && ["help", "--help", "-h"].include?(arguments.first)
      end

      def one_shot_prompt_argument
        prompt = @argv.join(" ").strip
        prompt.empty? ? nil : prompt
      end

      # Writes the command help output for the terminal CLI flow.
      def print_command_help(command_name = nil)
        if command_name.to_s.empty? || ["--help", "-h"].include?(command_name)
          print_help
          return
        end

        help = command_help[command_name]
        raise ArgumentError, "Unknown command: #{command_name}" unless help

        @prompt.say render_command_help(command_name, help)
      end

      # Writes the help output for the terminal CLI flow.
      def print_help
        command = ->(text) { colored(text, :green, :bold) }
        option = ->(text) { colored(text, :cyan) }
        heading = ->(text) { colored(text, :blue, :bold) }

        @prompt.say <<~HELP.rstrip
          #{colored("Kward", :green, :bold)} - an extendable CLI coding agent

          #{heading.call("Usage")}
            #{command.call("kward")}                              Start an interactive chat
            #{command.call("kward")} #{option.call('"Explain this project"')}       Run a one-shot prompt
            #{command.call("kward login")}                        Sign in or save provider credentials
            #{command.call("kward auth status")}                  Show saved credential status
            #{command.call("kward init")}                         Install starter prompts and PRINCIPLES.md
            #{command.call("kward doctor")}                       Check local Kward setup
            #{command.call("kward pan")}                          Start Pan mode web UI
            #{command.call("kward rpc")}                          Start the experimental JSON-RPC backend

          #{heading.call("Commands")}
            #{command.call("help")}                               Show this help
            #{command.call("version")}                            Show the installed Kward version
            #{command.call("login")} [anthropic|openrouter|github] Sign in with OpenAI, Anthropic, OpenRouter, or GitHub
            #{command.call("auth status|logout")}                 Show or clear saved credentials
            #{command.call("init")}                               Install starter prompts and PRINCIPLES.md
            #{command.call("doctor")}                             Check local Kward setup
            #{command.call("stats tokens")} [range] [options]      Export local token telemetry as CSV
            #{command.call("pan")}                                Start Pan mode web UI
            #{command.call("rpc")}                                Run the JSON-RPC backend for UI clients

          #{heading.call("Options")}
            #{option.call("--working-directory=PATH")}             Run Kward from PATH
            #{option.call("--help")}, #{option.call("-h")}                         Show this help
            #{option.call("--version")}, #{option.call("-v")}                      Show the installed version

          #{heading.call("Examples")}
            #{command.call("kward")}
            #{command.call("kward")} #{option.call('"Review this diff"')}
            #{command.call("git diff | kward")} #{option.call('"Review this diff"')}
            #{command.call("kward login openrouter")}
            #{command.call("kward stats tokens today --bucket hour")}

          Command names take precedence. Anything else is sent as a one-shot prompt.
        HELP
      end

      def command_help
        {
          "help" => {
            usage: "kward help [command]",
            description: "Show the top-level command overview or help for one command.",
            examples: ["kward help", "kward help pan"]
          },
          "version" => {
            usage: "kward version",
            description: "Show the installed Kward version.",
            examples: ["kward version", "kward --version"]
          },
          "login" => {
            usage: "kward login [anthropic|openrouter|github]",
            description: "Sign in with OpenAI, Anthropic, OpenRouter, or GitHub.",
            examples: ["kward login", "kward login anthropic", "kward login openrouter", "kward login github"]
          },
          "auth" => {
            usage: "kward auth status|logout",
            description: "Show or clear saved provider credentials without printing secrets.",
            examples: ["kward auth status", "kward auth logout"]
          },
          "init" => {
            usage: "kward init",
            description: "Install starter prompts and base PRINCIPLES.md into your config directory.",
            examples: ["kward init"]
          },
          "doctor" => {
            usage: "kward doctor",
            description: "Check local Kward configuration, workspace, auth hints, and writable directories.",
            examples: ["kward doctor", "kward --working-directory ~/code/project doctor"]
          },
          "stats" => {
            usage: "kward stats tokens [range] [--bucket second|minute|hour|day|week|month|year] [--output path]",
            description: "Export local token telemetry as CSV.",
            examples: ["kward stats tokens today", "kward stats tokens today --bucket hour", "kward stats tokens week --output tokens.csv"]
          },
          "pan" => {
            usage: "kward pan",
            description: "Start Pan mode, a minimal LAN web UI with a prompt textarea and transcript.",
            examples: ["kward pan", "kward --working-directory ~/code/project pan"]
          },
          "rpc" => {
            usage: "kward rpc",
            description: "Start the experimental JSON-RPC backend for UI clients.",
            examples: ["kward rpc", "kward --working-directory ~/code/project rpc"]
          }
        }
      end

      def render_command_help(name, help)
        heading = ->(text) { colored(text, :blue, :bold) }
        command = ->(text) { colored(text, :green, :bold) }

        lines = [
          "#{command.call(name)} - #{help.fetch(:description)}",
          "",
          heading.call("Usage"),
          "  #{command.call(help.fetch(:usage))}"
        ]
        examples = help.fetch(:examples, [])
        if examples.any?
          lines << ""
          lines << heading.call("Examples")
          examples.each { |example| lines << "  #{command.call(example)}" }
        end
        lines.join("\n")
      end

      def command_usage(name)
        "Usage: #{command_help.fetch(name).fetch(:usage)}"
      end

      # Writes the version output for the terminal CLI flow.
      def print_version
        @prompt.say "kward #{VERSION}"
      end

      def install_starter_pack
        result = StarterPackInstaller.install
        installed_count = result.installed.length
        skipped_count = result.skipped.length
        @prompt.say("Installed #{installed_count} starter pack file#{installed_count == 1 ? "" : "s"}.")
        @prompt.say("Skipped #{skipped_count} existing starter pack file#{skipped_count == 1 ? "" : "s"}.") if skipped_count.positive?
      rescue StandardError => e
        warn "Failed to install starter pack: #{e.message}"
        exit 1
      end

      def pan_mode?
        @argv.first == "pan"
      end

      def extract_global_options(arguments)
        remaining = []
        index = 0
        while index < arguments.length
          argument = arguments[index]
          case argument
          when "--"
            @prompt_delimited = true
            remaining.concat(arguments[(index + 1)..] || [])
            break
          when "--working-directory"
            index += 1
            raise ArgumentError, "Missing value for --working-directory" if index >= arguments.length

            @working_directory = expanded_working_directory(arguments[index])
          when /\A--working-directory=(.*)\z/
            @working_directory = expanded_working_directory(Regexp.last_match(1))
          else
            remaining << argument
          end
          index += 1
        end
        remaining
      end

      def expanded_working_directory(path)
        value = path.to_s.strip
        raise ArgumentError, "Missing value for --working-directory" if value.empty?

        expanded = File.expand_path(value)
        raise ArgumentError, "Working directory does not exist: #{expanded}" unless Dir.exist?(expanded)
        raise ArgumentError, "Working directory is not a directory: #{expanded}" unless File.directory?(expanded)

        expanded
      end

      def with_working_directory
        return yield unless @working_directory

        Dir.chdir(@working_directory) { yield }
      end

    end
  end
end

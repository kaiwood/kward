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
        heading = ->(text) { colored(text, :blue, :bold) }
        lines = ["#{colored("Kward", :green, :bold)} - an extensible CLI coding agent", ""]

        help_sections.each do |title, entries|
          lines << heading.call(title)
          lines.concat formatted_help_rows(entries, color: :green, bold: true)
          lines << ""
        end

        lines << heading.call("Options")
        lines.concat formatted_help_rows(help_options, color: :cyan)
        lines << ""
        lines << heading.call("Examples")
        lines.concat help_examples.map { |example| "  #{colored(example, :green, :bold)}" }
        lines << ""
        lines << "Command names take precedence. Anything else is sent as a one-shot prompt."
        @prompt.say lines.join("\n")
      end

      def help_sections
        {
          "Getting started" => [
            ["kward", "Start an interactive chat"],
            ["kward login [PROVIDER]", "Sign in or save provider credentials"],
            ["kward doctor", "Check local Kward setup"],
            ["kward init", "Install starter prompts and PRINCIPLES.md"]
          ],
          "Work" => [
            ["kward \"PROMPT\"", "Run a one-shot prompt"],
            ["kward --filter \"INSTRUCTION\"", "Filter standard input"],
            ["kward edit <filename>", "Open a file in the integrated editor"],
            ["kward sysprompt [--raw]", "Inspect the effective system prompt"]
          ],
          "Manage" => [
            ["kward auth status [--all]", "Show saved credential status"],
            ["kward hooks <command>", "Inspect lifecycle hooks"],
            ["kward skills <command>", "Manage project skill trust"],
            ["kward openrouter <command>", "Manage cached OpenRouter models"],
            ["kward stats tokens [range] [options]", "Export local token telemetry as CSV"]
          ],
          "Integrate" => [
            ["kward pan", "Start the local Pan web UI"],
            ["kward rpc", "Start the JSON-RPC backend"],
            ["kward transport <command>", "Manage transport plugins"]
          ],
          "Reference" => [
            ["kward help [command]", "Show help"],
            ["kward version", "Show the installed version"]
          ]
        }
      end

      def help_options
        [
          ["--working-directory=PATH", "Run Kward from PATH"],
          ["--mode=MODE", "Execution mode: auto, chat, oneshot, filter"],
          ["--filter", "Shortcut for --mode filter"],
          ["--skip-config", "Ignore the main config file for this run"],
          ["--help, -h", "Show help"],
          ["--version, -v", "Show the installed version"]
        ]
      end

      def help_examples
        [
          "kward",
          "kward \"Explain this project\"",
          "git diff | kward \"Summarize the main changes\"",
          "echo Hello | kward --filter \"Translate to German\"",
          "kward login openrouter",
          "kward edit lib/main.rb",
          "kward stats tokens today --bucket hour"
        ]
      end

      def formatted_help_rows(entries, color:, bold: false)
        width = entries.map { |label, _description| label.length }.max
        styles = [color]
        styles << :bold if bold
        entries.map do |label, description|
          "  #{colored(label.ljust(width), *styles)}  #{description}"
        end
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
            usage: "kward auth status [--all]|logout",
            description: "Show or clear saved provider credentials without printing secrets.",
            examples: ["kward auth status", "kward auth status --all", "kward auth logout"]
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
          "hooks" => {
            usage: "kward hooks [list|events|logs|doctor|trust|untrust]",
            description: "Inspect lifecycle hooks, recent audit records, diagnostics, and workspace hook trust.",
            examples: ["kward hooks list", "kward hooks doctor", "kward hooks logs 50", "kward hooks trust"]
          },
          "skills" => {
            usage: "kward skills [status|trust|untrust|review]",
            description: "Inspect or manage project skill trust for the current workspace.",
            examples: ["kward skills status", "kward skills review", "kward skills trust"]
          },
          "edit" => {
            usage: "kward edit <filename>",
            description: "Open a file in the integrated editor.",
            examples: ["kward edit lib/main.rb", "kward edit ~/notes/todo.md"]
          },
          "sysprompt" => {
            usage: "kward sysprompt [--raw]",
            description: "Inspect the effective system prompt for a new conversation in the current workspace.",
            examples: ["kward sysprompt", "kward sysprompt --raw", "kward --working-directory ~/code/project sysprompt"]
          },
          "stats" => {
            usage: "kward stats tokens [range] [--bucket second|minute|hour|day|week|month|year] [--output path]",
            description: "Export local token telemetry as CSV.",
            examples: ["kward stats tokens today", "kward stats tokens today --bucket hour", "kward stats tokens week --output tokens.csv"]
          },
          "openrouter" => {
            usage: "kward openrouter refresh|list",
            description: "Refresh or list cached text-capable OpenRouter models available to your API key.",
            examples: ["kward openrouter refresh", "kward openrouter --refresh", "kward openrouter list"]
          },
          "pan" => {
            usage: "kward pan",
            description: "Start Pan mode, a mobile-friendly local web UI with persistent sessions.",
            examples: ["kward pan", "kward --working-directory ~/code/project pan"]
          },
          "rpc" => {
            usage: "kward rpc",
            description: "Start the JSON-RPC backend for trusted local UI clients.",
            examples: ["kward rpc", "kward --working-directory ~/code/project rpc"]
          },
          "transport" => {
            usage: "kward transport list|status [NAME]|run NAME [WORKSPACE]",
            description: "Inspect or run trusted external transport plugins.",
            examples: ["kward transport list", "kward transport status", "kward transport run telegram", "kward transport run telegram ~/code/project"]
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
          when "--skip-config"
            @skip_config = true
          when "--filter"
            @requested_mode = "filter"
          when "--mode"
            index += 1
            raise ArgumentError, "Missing value for --mode" if index >= arguments.length

            @requested_mode = normalized_execution_mode(arguments[index])
          when /\A--mode=(.*)\z/
            @requested_mode = normalized_execution_mode(Regexp.last_match(1))
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

      def normalized_execution_mode(value)
        mode = value.to_s.strip.downcase
        modes = ["auto", "chat", "oneshot", "filter"]
        raise ArgumentError, "Unknown mode: #{value}. Expected one of: #{modes.join(", ")}" unless modes.include?(mode)

        mode
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

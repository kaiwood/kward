module Kward
  module ANSI
    ESCAPE_PATTERN = /\e\[[0-9;?]*[ -\/]*[@-~]/.freeze
    STYLES = {
      reset: 0,
      bold: 1,
      dim: 2,
      red: 31,
      green: 32,
      yellow: 33,
      blue: 34,
      magenta: 35,
      cyan: 36,
      gray: 90,
      grey: 90,
      primary_green: "38;2;138;160;106",
      bright_accent_green: "38;2;155;255;0",
      augen: "38;2;155;255;0",
      dark_forest_green: "38;2;78;88;53",
      stone: "38;2;196;192;178",
      metal_dark: "38;2;42;42;42",
      background: "38;2;22;24;22"
    }.freeze

    module_function

    def enabled?(output = $stdout, env: ENV)
      setting = env["KWARD_COLOR"].to_s.downcase
      return true if %w[always force forced true yes 1].include?(setting)
      return false if %w[never false no 0].include?(setting)
      return true if forced_color?(env)
      return false if disabled_color?(env)

      output.respond_to?(:tty?) && output.tty?
    end

    def colorize(text, *styles, enabled: enabled?)
      string = text.to_s
      return string unless enabled

      codes = styles.flatten.map { |style| STYLES.fetch(style, style) }.compact
      return string if codes.empty?

      "\e[#{codes.join(";")}m#{string}\e[0m"
    end

    def strip(text)
      text.to_s.gsub(ESCAPE_PATTERN, "")
    end

    def markdown(text, enabled: enabled?)
      string = text.to_s
      lines = string.lines(chomp: true)
      rendered = []
      in_fence = false

      lines.each do |line|
        if (match = line.match(/\A\s*```([^`]*)\s*\z/))
          if in_fence
            rendered << colorize("└" + "─" * 39, :gray, enabled: enabled)
            in_fence = false
          else
            language = match[1].to_s.strip
            label = language.empty? ? "code" : "code #{language}"
            rendered << colorize("┌─ #{label}", :gray, enabled: enabled)
            in_fence = true
          end
          next
        end

        if in_fence
          rendered << colorize("│ #{line}", :dim, enabled: enabled)
        elsif line.match?(/\A\#{1,6}\s+/)
          rendered << colorize(line, :bold, enabled: enabled)
        else
          rendered << inline_code(line, enabled: enabled)
        end
      end

      rendered << colorize("└" + "─" * 39, :gray, enabled: enabled) if in_fence
      rendered.join("\n") + (string.end_with?("\n") ? "\n" : "")
    end

    def inline_code(line, enabled: enabled?)
      line.gsub(/`([^`\n]+)`/) do
        "`#{colorize(Regexp.last_match(1), :dim, enabled: enabled)}`"
      end
    end

    def forced_color?(env)
      force_color = env["FORCE_COLOR"]
      clicolor_force = env["CLICOLOR_FORCE"]
      (force_color && force_color != "0") || (clicolor_force && clicolor_force != "0")
    end

    def disabled_color?(env)
      return true if env.key?("NO_COLOR") && !env["NO_COLOR"].to_s.empty?
      return true if env["CLICOLOR"] == "0"

      env["TERM"] == "dumb"
    end
  end
end

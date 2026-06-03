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
      grey: 90
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

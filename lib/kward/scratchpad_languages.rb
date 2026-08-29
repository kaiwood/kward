# Namespace for the Kward CLI agent runtime.
module Kward
  # Names, aliases, and display paths accepted by the scratchpad command.
  module ScratchpadLanguages
    LANGUAGES = {
      text: { aliases: %w[text txt], display_path: "scratchpad.txt" },
      ruby: { aliases: %w[ruby rb], display_path: "scratchpad.rb", runner: :ruby },
      erb: { aliases: %w[erb], display_path: "scratchpad.erb" },
      crystal: { aliases: %w[crystal cr], display_path: "scratchpad.cr", runner: :crystal },
      elixir: { aliases: %w[elixir ex exs], display_path: "scratchpad.ex", runner: :elixir },
      julia: { aliases: %w[julia jl], display_path: "scratchpad.jl", runner: :julia },
      javascript: { aliases: %w[javascript js jsx mjs cjs], display_path: "scratchpad.js", runner: :node },
      typescript: { aliases: %w[typescript ts tsx], display_path: "scratchpad.ts", runner: :node },
      json: { aliases: %w[json], display_path: "scratchpad.json" },
      markdown: { aliases: %w[markdown md], display_path: "scratchpad.md" },
      yaml: { aliases: %w[yaml yml], display_path: "scratchpad.yml" },
      shell: { aliases: %w[shell sh bash zsh fish], display_path: "scratchpad.sh", runner: :shell },
      makefile: { aliases: %w[makefile make mk], display_path: "scratchpad.mk" },
      html: { aliases: %w[html htm], display_path: "scratchpad.html" },
      css: { aliases: %w[css], display_path: "scratchpad.css" },
      scss: { aliases: %w[scss], display_path: "scratchpad.scss" },
      python: { aliases: %w[python py pyw], display_path: "scratchpad.py", runner: :python },
      go: { aliases: %w[go], display_path: "scratchpad.go", runner: :go },
      rust: { aliases: %w[rust rs], display_path: "scratchpad.rs" },
      java: { aliases: %w[java], display_path: "scratchpad.java" },
      csharp: { aliases: %w[csharp cs c#], display_path: "scratchpad.cs" },
      c: { aliases: %w[c], display_path: "scratchpad.c" },
      cpp: { aliases: %w[cpp cc cxx hpp hh hxx c++], display_path: "scratchpad.cpp" },
      swift: { aliases: %w[swift], display_path: "scratchpad.swift", runner: :swift },
      kotlin: { aliases: %w[kotlin kt kts], display_path: "scratchpad.kt" },
      lua: { aliases: %w[lua], display_path: "scratchpad.lua", runner: :lua },
      sql: { aliases: %w[sql], display_path: "scratchpad.sql" }
    }.freeze

    ALIASES = LANGUAGES.each_with_object({}) do |(language, definition), aliases|
      ([language.to_s] + definition.fetch(:aliases)).each do |name|
        aliases[name] = language
      end
    end.freeze

    module_function

    def normalize(language)
      value = language.to_s.strip.downcase
      return :text if value.empty?

      ALIASES.fetch(value) do
        raise ArgumentError, "Unknown scratchpad language #{language.inspect}. Use /scratchpad help for supported languages."
      end
    end

    def display_path(language)
      LANGUAGES.fetch(normalize(language)).fetch(:display_path)
    end

    def runner(language)
      LANGUAGES.fetch(normalize(language))[:runner]
    end

    def runnable?(language)
      !runner(language).nil?
    end

    def help_text
      lines = ["Supported scratchpad languages:"]
      LANGUAGES.each do |language, definition|
        aliases = definition.fetch(:aliases).reject { |name| name == language.to_s }
        suffix = aliases.empty? ? "" : " (#{aliases.join(", ")})"
        lines << "  #{language}#{suffix}"
      end
      lines.join("\n")
    end
  end
end

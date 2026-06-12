require "cgi"
require_relative "markdown_transcript"

module Kward
  class TranscriptExport
    SUPPORTED_FORMATS = ["markdown", "html"].freeze

    def self.format(value)
      format = value.to_s.strip.downcase
      format = "markdown" if format.empty? || format == "md"
      raise ArgumentError, "Unsupported export format: #{value}" unless SUPPORTED_FORMATS.include?(format)

      format
    end

    def self.content(conversation, format: "markdown")
      markdown = MarkdownTranscript.new(conversation).render
      return markdown if format(format) == "markdown"

      html(markdown)
    end

    def self.html(markdown)
      escaped = CGI.escapeHTML(markdown)
      <<~HTML
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <title>Kward Session</title>
        </head>
        <body>
        <pre>#{escaped}</pre>
        </body>
        </html>
      HTML
    end
    private_class_method :html
  end
end

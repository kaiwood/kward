require "nokogiri"
require "uri"
require_relative "web"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Fetches specific web resources for agent research workflows.
  class WebFetch
    DEFAULT_MAX_BYTES = 16 * 1024
    MAX_MAX_BYTES = 128 * 1024
    MAX_REDIRECTS = 5
    HTTP_TIMEOUT_SECONDS = 10

    # Creates a fetcher for web content and raw resources.
    def initialize(http_client: WebSearch::NetHttpClient.new)
      @http_client = http_client
    end

    # Fetches a URL and extracts readable text for human-facing pages.
    def fetch_content(args)
      url = args_value(args, "url").to_s.strip
      return "Error: url is required" if url.empty?

      max_bytes = bounded_max_bytes(args_value(args, "max_bytes") || args_value(args, "maxBytes"))
      extract = normalize_extract(args_value(args, "extract") || "auto")
      return "Error: extract must be one of: auto, text, markdown" unless extract

      response = fetch_url(url, max_bytes: max_bytes)
      return response if response.is_a?(String)

      body = response[:body].to_s
      content_type = header_value(response[:headers], "content-type")
      text = extract_readable_text(body, content_type: content_type, mode: extract)
      text = truncate_bytes(text, max_bytes)

      [
        "# Fetched content",
        "- URL: #{response[:url]}",
        "- Content type: #{content_type.empty? ? "unknown" : content_type}",
        "- Bytes returned: #{text.bytesize}",
        "",
        text.empty? ? "(No readable text extracted.)" : text
      ].join("\n")
    rescue StandardError => e
      "Error: fetch_content failed: #{e.message}"
    end

    # Fetches a URL and returns bounded raw response content.
    def fetch_raw(args)
      url = args_value(args, "url").to_s.strip
      return "Error: url is required" if url.empty?

      max_bytes = bounded_max_bytes(args_value(args, "max_bytes") || args_value(args, "maxBytes"))
      accept = args_value(args, "accept").to_s.strip
      response = fetch_url(url, max_bytes: max_bytes, accept: accept.empty? ? "*/*" : accept)
      return response if response.is_a?(String)

      body = truncate_bytes(response[:body].to_s, max_bytes)
      content_type = header_value(response[:headers], "content-type")
      [
        "# Fetched raw content",
        "- URL: #{response[:url]}",
        "- Content type: #{content_type.empty? ? "unknown" : content_type}",
        "- Bytes returned: #{body.bytesize}",
        "",
        body
      ].join("\n")
    rescue StandardError => e
      "Error: fetch_raw failed: #{e.message}"
    end

    private

    def fetch_url(url, max_bytes:, accept: "text/html,application/xhtml+xml,text/plain;q=0.9,*/*;q=0.8")
      current_url = normalize_url(url)
      redirects = 0

      loop do
        response = @http_client.get(current_url, headers: browser_headers(accept))
        code = response.code.to_i
        headers = response_headers(response)

        if redirect?(code)
          return "Error: too many redirects" if redirects >= MAX_REDIRECTS

          location = header_value(headers, "location")
          return "Error: redirect missing Location header" if location.empty?

          current_url = normalize_url(URI.join(current_url, location).to_s)
          redirects += 1
          next
        end

        return "Error: fetch failed with HTTP #{response.code}" unless code.between?(200, 299)

        body = response.body.to_s
        body = truncate_bytes(body, max_bytes)
        return { url: current_url, headers: headers, body: body }
      end
    end

    def normalize_url(value)
      uri = URI.parse(value.to_s.strip)
      raise "url must use http or https" unless %w[http https].include?(uri.scheme)
      raise "url host is required" if uri.host.to_s.empty?

      uri.to_s
    rescue URI::InvalidURIError
      raise "invalid url"
    end

    def response_headers(response)
      return {} unless response.respond_to?(:headers) && response.headers.is_a?(Hash)

      response.headers.transform_keys { |key| key.to_s.downcase }
    end

    def header_value(headers, key)
      headers[key.to_s.downcase].to_s
    end

    def redirect?(code)
      [301, 302, 303, 307, 308].include?(code)
    end

    def bounded_max_bytes(value)
      number = value.to_i
      number = DEFAULT_MAX_BYTES if number <= 0
      [number, MAX_MAX_BYTES].min
    end

    def normalize_extract(value)
      normalized = value.to_s.strip.downcase
      %w[auto text markdown].include?(normalized) ? normalized : nil
    end

    def extract_readable_text(body, content_type:, mode:)
      return clean_text(body) if mode == "text" || !html_content?(content_type, body)

      document = Nokogiri::HTML(body)
      document.css("script, style, noscript, svg, nav, footer, form").remove
      title = document.at_css("title")&.text.to_s.strip
      root = document.at_css("article") || document.at_css("main") || document.at_css("body") || document
      parts = []
      parts << "# #{clean_text(title)}" unless title.empty?
      root.css("h1, h2, h3, h4, h5, h6, p, li, pre, code, blockquote").each do |node|
        text = clean_text(node.text)
        next if text.empty?

        parts << format_html_node(node, text, mode: mode)
      end
      parts.uniq.join("\n\n")
    end

    def html_content?(content_type, body)
      content_type.to_s.include?("html") || body.to_s.lstrip.start_with?("<!DOCTYPE html", "<html", "<HTML")
    end

    def format_html_node(node, text, mode:)
      return text if mode == "text"

      case node.name
      when /^h([1-6])$/
        "#{"#" * Regexp.last_match(1).to_i} #{text}"
      when "li"
        "- #{text}"
      when "pre", "code"
        "```\n#{text}\n```"
      when "blockquote"
        "> #{text}"
      else
        text
      end
    end

    def clean_text(text)
      text.to_s.gsub(/\s+/, " ").strip
    end

    def truncate_bytes(text, max_bytes)
      return text if text.bytesize <= max_bytes

      "#{text.byteslice(0, max_bytes).to_s.scrub}\n... truncated to #{max_bytes} bytes"
    end

    def browser_headers(accept)
      {
        "Accept" => accept,
        "Accept-Language" => "en-US,en;q=0.9",
        "User-Agent" => "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36"
      }
    end

    def args_value(args, key)
      return nil unless args.is_a?(Hash)
      return args[key] if args.key?(key)
      return args[key.to_sym] if args.key?(key.to_sym)

      nil
    end
  end
end

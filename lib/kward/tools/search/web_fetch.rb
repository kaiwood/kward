require "nokogiri"
require "uri"
require_relative "web"
require_relative "../../http"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Fetches specific web resources for agent research workflows.
  class WebFetch
    DEFAULT_MAX_BYTES = 16 * 1024
    MAX_MAX_BYTES = 128 * 1024
    MAX_REDIRECTS = 5
    MAX_DOWNLOAD_BYTES = 2 * 1024 * 1024
    HTTP_TIMEOUT_SECONDS = 10
    MAX_DISCOVERED_LINKS = 50

    # Creates a fetcher for web content and raw resources.
    def initialize(http_client: WebSearch::NetHttpClient.new)
      @http_client = http_client
    end

    # Fetches a URL and extracts readable text for human-facing pages.
    def fetch_content(args = nil, cancellation: nil, **keyword_args)
      args ||= keyword_args
      cancellation&.raise_if_cancelled!
      url = args_value(args, "url").to_s.strip
      return "Error: url is required" if url.empty?

      max_bytes = bounded_max_bytes(args_value(args, "max_bytes") || args_value(args, "maxBytes"))
      extract = normalize_extract(args_value(args, "extract") || "auto")
      return "Error: extract must be one of: auto, text, markdown" unless extract

      response = fetch_url(url, max_bytes: MAX_DOWNLOAD_BYTES, cancellation: cancellation)
      return response if response.is_a?(String)
      return "Error: response exceeds #{MAX_DOWNLOAD_BYTES} byte download limit" if response[:truncated]

      body = response[:body].to_s
      content_type = header_value(response[:headers], "content-type")
      text = extract_readable_text(body, content_type: content_type, mode: extract, base_url: response[:url])
      text, truncated = truncate_bytes(text, max_bytes)

      [
        "# Fetched content",
        "- URL: #{response[:url]}",
        "- Content type: #{content_type.empty? ? "unknown" : content_type}",
        "- Downloaded bytes: #{body.bytesize}",
        "- Bytes returned: #{text.bytesize}",
        "- Truncated: #{truncated ? "yes" : "no"}",
        "",
        text.empty? ? "(No readable text extracted.)" : text
      ].join("\n")
    rescue Cancellation::CancelledError
      raise
    rescue StandardError => e
      "Error: fetch_content failed: #{e.message}"
    end

    # Fetches a URL and returns bounded raw response content.
    def fetch_raw(args = nil, cancellation: nil, **keyword_args)
      args ||= keyword_args
      cancellation&.raise_if_cancelled!
      url = args_value(args, "url").to_s.strip
      return "Error: url is required" if url.empty?

      max_bytes = bounded_max_bytes(args_value(args, "max_bytes") || args_value(args, "maxBytes"))
      accept = args_value(args, "accept").to_s.strip
      response = fetch_url(url, max_bytes: max_bytes, accept: accept.empty? ? "*/*" : accept, cancellation: cancellation)
      return response if response.is_a?(String)

      body = response[:body].to_s
      content_type = header_value(response[:headers], "content-type")
      body = "#{body.to_s.scrub}\n... truncated to #{max_bytes} bytes" if response[:truncated]
      [
        "# Fetched raw content",
        "- URL: #{response[:url]}",
        "- Content type: #{content_type.empty? ? "unknown" : content_type}",
        "- Bytes returned: #{response[:body].to_s.bytesize}",
        "- Truncated: #{response[:truncated] ? "yes" : "no"}",
        "",
        body
      ].join("\n")
    rescue Cancellation::CancelledError
      raise
    rescue StandardError => e
      "Error: fetch_raw failed: #{e.message}"
    end

    private

    def fetch_url(url, max_bytes:, accept: "text/html,application/xhtml+xml,text/plain;q=0.9,*/*;q=0.8", cancellation: nil)
      current_url = normalize_url(url)
      redirects = 0

      loop do
        cancellation&.raise_if_cancelled!
        response = @http_client.get(current_url, headers: browser_headers(accept), max_bytes: max_bytes)
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

        return { url: current_url, headers: headers, body: response.body.to_s, truncated: response.respond_to?(:truncated) && response.truncated }
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

    def extract_readable_text(body, content_type:, mode:, base_url:)
      return clean_text(body) unless html_content?(content_type, body)

      document = Nokogiri::HTML(body)
      links = discovered_links(document, base_url)
      document.css("script, style, noscript, template, svg, canvas, nav, footer, #footer, [role='contentinfo'], form, iframe, [hidden], [aria-hidden='true']").remove
      title = clean_text(document.at_css("title")&.text)
      root = document.at_css("main") || document.at_css("[role='main']") || document.at_css("article") || document.at_css("body") || document
      parts = []
      parts << (mode == "text" ? title : "# #{title}") unless title.empty?
      parts.concat(readable_blocks(root, mode: mode, base_url: base_url))
      parts << format_discovered_links(links, mode: mode) unless links.empty?
      parts.reject(&:empty?).uniq.join("\n\n")
    end

    def html_content?(content_type, body)
      content_type.to_s.include?("html") || body.to_s.lstrip.start_with?("<!DOCTYPE html", "<html", "<HTML")
    end

    def readable_blocks(root, mode:, base_url:)
      selector = "h1, h2, h3, h4, h5, h6, p, ul, ol, pre, blockquote, table, a[href]"
      root.css(selector).filter_map do |node|
        next if nested_readable_block?(node)

        format_html_node(node, mode: mode, base_url: base_url)
      end
    end

    def nested_readable_block?(node)
      block_names = %w[p ul ol pre blockquote table]
      return true if node.ancestors.any? { |ancestor| block_names.include?(ancestor.name) }
      return false unless node.name == "a"

      node.ancestors.any? { |ancestor| ancestor.name.match?(/\Ah[1-6]\z/) }
    end

    def format_html_node(node, mode:, base_url:)
      case node.name
      when /^h([1-6])$/
        level = Regexp.last_match(1).to_i
        text = render_inline(node, mode: mode, base_url: base_url)
        return "" if text.empty?

        mode == "text" ? text : "#{"#" * level} #{text}"
      when "p"
        render_inline(node, mode: mode, base_url: base_url)
      when "a"
        format_link(node, mode: mode, base_url: base_url)
      when "ul", "ol"
        format_list(node, mode: mode, base_url: base_url)
      when "pre"
        text = node.text.to_s.strip
        mode == "text" ? text : "```\n#{text}\n```"
      when "blockquote"
        text = render_inline(node, mode: mode, base_url: base_url)
        mode == "text" ? text : text.lines.map { |line| "> #{line}" }.join
      when "table"
        format_table(node, mode: mode, base_url: base_url)
      end
    end

    def render_inline(node, mode:, base_url:)
      text = node.children.map do |child|
        if child.text?
          child.text
        elsif child.name == "a"
          format_link(child, mode: mode, base_url: base_url)
        elsif child.name == "code" && mode != "text"
          "`#{clean_text(child.text)}`"
        elsif child.name == "br"
          "\n"
        else
          render_inline(child, mode: mode, base_url: base_url)
        end
      end.join
      clean_text(text)
    end

    def format_link(node, mode:, base_url:)
      label = clean_text(node.text)
      href = resolved_link(node["href"], base_url)
      return label unless href

      label = href if label.empty?
      mode == "text" ? "#{label} (#{href})" : "[#{label}](#{href})"
    end

    def format_list(list, mode:, base_url:, depth: 0)
      ordered = list.name == "ol"
      list.element_children.select { |child| child.name == "li" }.each_with_index.map do |item, index|
        nested_lists = item.element_children.select { |child| %w[ul ol].include?(child.name) }
        copy = item.dup
        copy.css("ul, ol").remove
        text = render_inline(copy, mode: mode, base_url: base_url)
        marker = ordered ? "#{index + 1}." : "-"
        line = "#{"  " * depth}#{marker} #{text}".rstrip
        nested = nested_lists.map { |nested_list| format_list(nested_list, mode: mode, base_url: base_url, depth: depth + 1) }
        ([line] + nested).reject(&:empty?).join("\n")
      end.join("\n")
    end

    def format_table(table, mode:, base_url:)
      rows = table.css("tr").map do |row|
        row.css("th, td").map { |cell| render_inline(cell, mode: mode, base_url: base_url) }
      end.reject(&:empty?)
      return "" if rows.empty?

      width = rows.map(&:length).max
      rows.each { |row| row.fill("", row.length...width) }
      if mode == "text"
        rows.map { |row| row.join(" | ") }.join("\n")
      else
        header = rows.first
        body = rows.drop(1)
        (["| #{header.join(" | ")} |", "| #{Array.new(width, "---").join(" | ")} |"] + body.map { |row| "| #{row.join(" | ")} |" }).join("\n")
      end
    end

    def clean_text(text)
      text.to_s.gsub(/\s+/, " ").strip
    end

    def discovered_links(document, base_url)
      candidates = document.css("a[href]").each_with_index.filter_map do |link, index|
        href = resolved_link(link["href"], base_url)
        label = clean_text(link.text)
        label = clean_text(link["aria-label"] || link["title"]) if label.empty?
        next if href.nil? || label.empty? || skip_link?(link, label)

        [link_group(link), label, href, index]
      end
      priorities = { "Main content" => 0, "Primary navigation" => 1, "Page links" => 2, "Footer" => 3 }
      candidates.sort_by! { |group, _label, _href, index| [priorities.fetch(group, 4), index] }

      groups = Hash.new { |hash, key| hash[key] = [] }
      seen = {}
      candidates.each do |group, label, href, _index|
        next if seen[href]

        seen[href] = true
        groups[group] << [label, href]
      end
      omitted = [seen.length - MAX_DISCOVERED_LINKS, 0].max
      allowed = MAX_DISCOVERED_LINKS
      groups.each_value do |links|
        links.replace(links.shift(allowed))
        allowed -= links.length
      end
      groups.delete_if { |_group, links| links.empty? }
      groups["Omitted"] << [omitted.to_s, nil] if omitted.positive?
      groups
    end

    def link_group(link)
      return "Primary navigation" unless link.ancestors("nav").empty?
      return "Footer" unless link.ancestors("footer, #footer, [role='contentinfo']").empty?
      return "Main content" unless link.ancestors("main, [role='main']").empty?

      "Page links"
    end

    def skip_link?(link, label)
      link["class"].to_s.split.include?("kward-skip-link") || label.match?(/\Askip to (?:content|main)/i)
    end

    def resolved_link(href, base_url)
      value = href.to_s.strip
      return nil if value.empty? || value.start_with?("javascript:", "data:")

      uri = URI.join(base_url, value)
      return nil unless %w[http https].include?(uri.scheme)

      uri.to_s
    rescue URI::InvalidURIError
      nil
    end

    def format_discovered_links(groups, mode:)
      omitted = groups.delete("Omitted")&.first&.first.to_i
      heading = mode == "text" ? "Links" : "## Links"
      sections = groups.filter_map do |group, links|
        next if links.empty?

        group_heading = mode == "text" ? group : "### #{group}"
        entries = links.map do |label, href|
          mode == "text" ? "- #{label}: #{href}" : "- [#{label}](#{href})"
        end
        ([group_heading] + entries).join("\n")
      end
      sections << "#{omitted} additional links omitted." if omitted.positive?
      ([heading] + sections).join("\n\n")
    end

    def truncate_bytes(text, max_bytes)
      return [text, false] if text.bytesize <= max_bytes

      marker = "\n... extracted content truncated ..."
      available = [max_bytes - marker.bytesize, 0].max
      truncated = text.byteslice(0, available).to_s.scrub.sub(/\n?[^\n]*\z/, "")
      ["#{truncated}#{marker}", true]
    end

    def browser_headers(accept)
      {
        "Accept" => accept,
        "Accept-Language" => "en-US,en;q=0.9",
        "User-Agent" => Http.user_agent
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

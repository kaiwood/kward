require "cgi"
require "json"
require "net/http"
require "nokogiri"
require "uri"

module Kward
  class WebResearch
    DEFAULT_MAX_RESULTS = 5
    MAX_MAX_RESULTS = 10
    MAX_QUERIES = 4
    MAX_OUTPUT_BYTES = 20 * 1024
    HTTP_TIMEOUT_SECONDS = 10
    DUCKDUCKGO_URL = "https://html.duckduckgo.com/html/"
    PUBLIC_SEARXNG_INSTANCES = [
      "https://searx.be",
      "https://search.inetol.net",
      "https://searx.tiekoetter.com"
    ].freeze

    Result = Struct.new(:title, :url, :excerpt, :provider, keyword_init: true)

    def initialize(http_client: NetHttpClient.new, searxng_instances: PUBLIC_SEARXNG_INSTANCES, max_output_bytes: MAX_OUTPUT_BYTES)
      @http_client = http_client
      @searxng_instances = searxng_instances
      @max_output_bytes = max_output_bytes
    end

    def search(args)
      queries = args_value(args, "queries")
      return "Error: queries must be an array with 1-#{MAX_QUERIES} strings" unless valid_queries?(queries)

      max_results = bounded_max_results(args_value(args, "max_results"))
      sections = ["# Web research"]
      failures = []
      any_results = false

      queries.each do |query|
        results, error = search_query(query, max_results)
        any_results = true unless results.empty?
        failures << "#{query}: #{error}" if error && results.empty?
        sections << format_query_results(query, results, error)
      end

      unless any_results
        return "Error: web_research found no results\n#{failures.map { |failure| "- #{failure}" }.join("\n")}".strip
      end

      truncate_output(sections.join("\n\n"))
    end

    private

    def search_query(query, max_results)
      begin
        duckduckgo_results = duckduckgo_search(query, max_results)
        return [duckduckgo_results, nil] unless duckduckgo_results.empty?

        duckduckgo_error = "DuckDuckGo returned no results"
      rescue StandardError => e
        duckduckgo_error = e.message
      end

      searxng_results, searxng_error = searxng_search(query, max_results)
      error = [duckduckgo_error, searxng_error].compact.join("; ")
      [searxng_results, error.empty? ? nil : error]
    end

    def duckduckgo_search(query, max_results)
      response = @http_client.post(
        DUCKDUCKGO_URL,
        form: { "q" => query, "kl" => "wt-wt" },
        headers: browser_headers("text/html")
      )
      raise "DuckDuckGo search failed with HTTP #{response.code}" unless success?(response)

      document = Nokogiri::HTML(response.body.to_s)
      document.css("div.result").first(max_results).filter_map do |node|
        link = node.at_css("a.result__a") || node.at_css("h2 a") || node.at_css("a[href]")
        next unless link

        Result.new(
          title: clean_text(link.text),
          url: clean_result_url(link["href"].to_s),
          excerpt: clean_text((node.at_css("a.result__snippet") || node.at_css(".result__snippet"))&.text),
          provider: "duckduckgo"
        )
      end.reject { |result| result.title.empty? || result.url.empty? }
    end

    def searxng_search(query, max_results)
      errors = []

      @searxng_instances.each do |instance|
        begin
          results = searxng_instance_search(instance, query, max_results)
          return [results, nil] unless results.empty?

          errors << "#{instance} returned no results"
        rescue StandardError => e
          errors << "#{instance}: #{e.message}"
        end
      end

      [[], errors.join("; ")]
    end

    def searxng_instance_search(instance, query, max_results)
      begin
        results = searxng_json_search(instance, query, max_results)
        return results unless results.empty?

        json_error = "SearXNG JSON search returned no results"
      rescue StandardError => e
        json_error = e.message
      end

      begin
        results = searxng_html_search(instance, query, max_results)
        return results unless results.empty?

        raise "SearXNG HTML search returned no results"
      rescue StandardError => e
        raise "#{json_error}; #{e.message}"
      end
    end

    def searxng_json_search(instance, query, max_results)
      uri = searxng_search_uri(instance, q: query, format: "json")
      response = @http_client.get(uri.to_s, headers: { "Accept" => "application/json" })
      raise "SearXNG search failed with HTTP #{response.code}" unless success?(response)

      data = JSON.parse(response.body.to_s)
      results_from_records(Array(data["results"]), max_results)
    end

    def searxng_html_search(instance, query, max_results)
      uri = searxng_search_uri(instance, q: query)
      response = @http_client.get(uri.to_s, headers: browser_headers("text/html"))
      raise "SearXNG HTML search failed with HTTP #{response.code}" unless success?(response)

      document = Nokogiri::HTML(response.body.to_s)
      records = document.css("article.result, div.result").map do |node|
        link = node.at_css("h3 a, a[href]")
        next unless link

        {
          "title" => link.text,
          "url" => link["href"],
          "content" => node.at_css(".content, p")&.text
        }
      end.compact
      results_from_records(records, max_results)
    end

    def searxng_search_uri(instance, params)
      uri = URI.join(instance.end_with?("/") ? instance : "#{instance}/", "search")
      uri.query = URI.encode_www_form(params)
      uri
    end

    def results_from_records(records, max_results)
      records.first(max_results).filter_map do |record|
        result_from_hash(record, "searxng")
      end
    end

    def result_from_hash(record, provider)
      return nil unless record.is_a?(Hash)

      title = clean_text(record["title"].to_s)
      url = clean_result_url(record["url"].to_s)
      excerpt = clean_text((record["content"] || record["snippet"] || record["description"]).to_s)
      return nil if title.empty? || url.empty?

      Result.new(title: title, url: url, excerpt: excerpt, provider: provider)
    end

    def format_query_results(query, results, error)
      lines = ["## Query: #{query}"]
      lines << "Provider fallback note: #{error}" if error && !results.empty?
      results.each_with_index do |result, index|
        lines << "#{index + 1}. #{result.title}"
        lines << "   URL: #{result.url}"
        lines << "   Provider: #{result.provider}"
        lines << "   Excerpt: #{result.excerpt}" unless result.excerpt.to_s.empty?
      end
      lines << "No results. #{error}" if results.empty?
      lines.join("\n")
    end

    def bounded_max_results(value)
      max_results = value.to_i
      max_results = DEFAULT_MAX_RESULTS if max_results <= 0
      [max_results, MAX_MAX_RESULTS].min
    end

    def valid_queries?(queries)
      queries.is_a?(Array) && queries.length.between?(1, MAX_QUERIES) && queries.all? { |query| query.is_a?(String) && !query.strip.empty? }
    end

    def args_value(args, key)
      return nil unless args.is_a?(Hash)

      args[key] || args[key.to_sym]
    end

    def success?(response)
      response.code.to_i.between?(200, 299)
    end

    def clean_text(text)
      text.to_s.gsub(/\s+/, " ").strip
    end

    def clean_result_url(url)
      text = url.to_s.strip
      uri = URI.parse(text)
      if uri.host == "duckduckgo.com" && uri.path == "/l/"
        params = URI.decode_www_form(uri.query.to_s).to_h
        return params["uddg"].to_s unless params["uddg"].to_s.empty?
      end
      text
    rescue URI::InvalidURIError
      text
    end

    def browser_headers(accept)
      {
        "Accept" => accept,
        "Accept-Language" => "en-US,en;q=0.9",
        "User-Agent" => "Mozilla/5.0 (compatible; KwardWebResearch/1.0)",
        "Sec-Fetch-Mode" => "navigate"
      }
    end

    def truncate_output(output)
      return output if output.bytesize <= @max_output_bytes

      truncated = output.byteslice(0, @max_output_bytes).to_s.scrub
      "#{truncated}\n... truncated to #{@max_output_bytes} bytes"
    end

    class NetHttpClient
      Response = Struct.new(:code, :body, keyword_init: true)

      def get(url, headers: {})
        request(url, Net::HTTP::Get, headers: headers)
      end

      def post(url, form:, headers: {})
        request(url, Net::HTTP::Post, headers: headers) do |http_request|
          http_request.set_form_data(form)
        end
      end

      private

      def request(url, request_class, headers: {})
        uri = URI.parse(url)
        Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: HTTP_TIMEOUT_SECONDS, read_timeout: HTTP_TIMEOUT_SECONDS) do |http|
          http_request = request_class.new(uri)
          headers.each { |key, value| http_request[key] = value }
          yield http_request if block_given?
          response = http.request(http_request)
          Response.new(code: response.code, body: response.body)
        end
      end
    end
  end
end

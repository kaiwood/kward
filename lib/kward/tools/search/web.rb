require "cgi"
require "json"
require "net/http"
require "nokogiri"
require "uri"
require_relative "../../config_files"

module Kward
  class WebSearch
    DEFAULT_MAX_RESULTS = 5
    MAX_MAX_RESULTS = 20
    MAX_QUERIES = 4
    MAX_OUTPUT_BYTES = 8 * 1024
    MODEL_PROVIDER_MAX_TOKENS = 512
    MAX_ANSWER_CHARS = 2_000
    MAX_EXCERPT_CHARS = 300
    HTTP_TIMEOUT_SECONDS = 10
    DUCKDUCKGO_URL = "https://html.duckduckgo.com/html/"
    EXA_MCP_URL = "https://mcp.exa.ai/mcp"
    EXA_ANSWER_URL = "https://api.exa.ai/answer"
    EXA_SEARCH_URL = "https://api.exa.ai/search"
    PERPLEXITY_API_URL = "https://api.perplexity.ai/chat/completions"
    GEMINI_API_BASE = "https://generativelanguage.googleapis.com/v1beta"
    DEFAULT_GEMINI_MODEL = "gemini-2.5-flash"
    PUBLIC_SEARXNG_INSTANCES = [
      "https://searx.be",
      "https://search.inetol.net",
      "https://searx.tiekoetter.com"
    ].freeze
    PROVIDERS = %w[auto exa perplexity gemini legacy duckduckgo].freeze

    Result = Struct.new(:title, :url, :excerpt, :provider, keyword_init: true)
    SearchResponse = Struct.new(:answer, :results, :provider, :note, keyword_init: true)

    def initialize(http_client: NetHttpClient.new, searxng_instances: PUBLIC_SEARXNG_INSTANCES, max_output_bytes: MAX_OUTPUT_BYTES, config: nil)
      @http_client = http_client
      @searxng_instances = searxng_instances
      @max_output_bytes = max_output_bytes
      @config = config
    end

    def available?
      enabled = boolean_config_value("enabled")
      return enabled unless enabled.nil?

      true
    end

    def search(args)
      queries = args_value(args, "queries")
      return "Error: queries must be an array with 1-#{MAX_QUERIES} strings" unless valid_queries?(queries)

      max_results = bounded_max_results(args_value(args, "max_results") || args_value(args, "num_results"))
      provider = normalize_provider(args_value(args, "provider") || config_value("provider") || "auto")
      return "Error: provider must be one of: #{PROVIDERS.join(", ")}" unless provider

      options = {
        max_results: max_results,
        recency_filter: normalize_recency(args_value(args, "recency_filter") || args_value(args, "recencyFilter")),
        domain_filter: normalize_domain_filter(args_value(args, "domain_filter") || args_value(args, "domainFilter")),
        provider: provider
      }

      sections = ["# Web search"]
      failures = []
      any_results = false

      queries.each do |query|
        response, error = search_query(query, options)
        any_results = true if successful_response?(response)
        failures << "#{query}: #{error}" if error && !successful_response?(response)
        sections << format_query_results(query, response, error)
      end

      unless any_results
        return "Error: web_search found no results\n#{failures.map { |failure| "- #{failure}" }.join("\n")}".strip
      end

      truncate_output(sections.join("\n\n"))
    end

    private

    def search_query(query, options)
      errors = []
      provider_order(options[:provider]).each do |provider|
        begin
          response = case provider
                     when "exa"
                       exa_search(query, options)
                     when "perplexity"
                       perplexity_search(query, options)
                     when "gemini"
                       gemini_search(query, options)
                     when "legacy"
                       legacy_search(query, options)
                     end
          return [response, errors.empty? ? nil : errors.join("; ")] if successful_response?(response)
          errors << "#{provider}: no results"
        rescue StandardError => e
          errors << "#{provider}: #{redact_secrets(e.message)}"
        end
      end

      [nil, errors.join("; ")]
    end

    def provider_order(provider)
      case provider
      when "auto"
        order = ["exa"]
        if allow_model_provider_fallback?
          order << "perplexity" if api_key("perplexity")
          order << "gemini" if api_key("gemini")
        end
        order << "legacy"
        order
      when "duckduckgo"
        ["legacy"]
      else
        [provider]
      end
    end

    def exa_search(query, options)
      key = api_key("exa")
      return exa_api_search(query, options, key) if key

      exa_mcp_search(query, options)
    rescue StandardError
      raise if key.nil?

      # A configured key should not make the no-key path worse; fall back to Exa MCP.
      exa_mcp_search(query, options)
    end

    def exa_mcp_search(query, options)
      text = call_exa_mcp(
        "web_search_exa",
        {
          "query" => enriched_query(query, options),
          "numResults" => options[:max_results],
          "livecrawl" => "fallback",
          "type" => "auto",
          "contextMaxCharacters" => 3000
        }
      )
      results = parse_exa_mcp_results(text, options[:max_results])
      SearchResponse.new(answer: answer_from_results(results), results: results, provider: "exa")
    end

    def call_exa_mcp(tool_name, arguments)
      response = @http_client.post_json(
        EXA_MCP_URL,
        body: {
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "tools/call",
          "params" => { "name" => tool_name, "arguments" => arguments }
        },
        headers: {
          "Accept" => "application/json, text/event-stream",
          "Content-Type" => "application/json"
        }
      )
      raise "Exa MCP failed with HTTP #{response.code}" unless success?(response)

      parsed = parse_mcp_rpc_response(response.body.to_s)
      raise "Exa MCP returned an empty response" unless parsed
      if parsed["error"].is_a?(Hash)
        raise "Exa MCP error: #{parsed["error"]["message"] || "unknown error"}"
      end

      result = parsed["result"]
      if result.is_a?(Hash) && result["isError"]
        message = Array(result["content"]).find { |item| item.is_a?(Hash) && item["type"] == "text" }.to_h["text"]
        raise(message.to_s.empty? ? "Exa MCP returned an error" : message.to_s)
      end

      text = Array(result.to_h["content"]).find { |item| item.is_a?(Hash) && item["type"] == "text" }.to_h["text"].to_s
      raise "Exa MCP returned empty content" if text.strip.empty?

      text
    end

    def parse_mcp_rpc_response(body)
      body.each_line do |line|
        stripped_line = line.strip
        next unless stripped_line.start_with?("data:")

        payload = stripped_line.delete_prefix("data:").strip
        next if payload.empty? || payload == "[DONE]"

        parsed = JSON.parse(payload)
        return parsed if parsed.is_a?(Hash) && (parsed.key?("result") || parsed.key?("error"))
      rescue JSON::ParserError
        next
      end

      parsed = JSON.parse(body)
      parsed if parsed.is_a?(Hash) && (parsed.key?("result") || parsed.key?("error"))
    rescue JSON::ParserError
      nil
    end

    def parse_exa_mcp_results(text, max_results)
      blocks = text.split(/(?=^Title: )/).map(&:strip).reject(&:empty?)
      parsed = blocks.filter_map do |block|
        title = block[/^Title: (.+)/, 1].to_s.strip
        url = block[/^URL: (.+)/, 1].to_s.strip
        next if url.empty?

        content = ""
        if (index = block.index("\nText: "))
          content = block[(index + 7)..].to_s.strip
        elsif (match = block.match(/\nHighlights:\s*\n/))
          content = block[(match.end(0))..].to_s.strip
        end
        content = content.sub(/\n---\s*\z/, "").strip
        Result.new(title: title.empty? ? url : title, url: url, excerpt: truncate_text(content, MAX_EXCERPT_CHARS), provider: "exa")
      end

      parsed.first(max_results)
    end

    def exa_api_search(query, options, key)
      if options[:recency_filter] || options[:domain_filter].any? || options[:max_results] != DEFAULT_MAX_RESULTS
        exa_api_structured_search(query, options, key)
      else
        exa_api_answer_search(query, key)
      end
    end

    def exa_api_answer_search(query, key)
      response = @http_client.post_json(
        EXA_ANSWER_URL,
        body: { "query" => query, "text" => true },
        headers: { "x-api-key" => key, "Content-Type" => "application/json" }
      )
      raise "Exa API failed with HTTP #{response.code}: #{response.body.to_s[0, 300]}" unless success?(response)

      data = JSON.parse(response.body.to_s)
      results = results_from_exa_records(Array(data["citations"]), DEFAULT_MAX_RESULTS)
      SearchResponse.new(answer: truncate_text(data["answer"], MAX_ANSWER_CHARS), results: results, provider: "exa")
    end

    def exa_api_structured_search(query, options, key)
      body = {
        "query" => query,
        "type" => "auto",
        "numResults" => options[:max_results],
        "contents" => { "text" => { "maxCharacters" => 3000 }, "highlights" => true }
      }.merge(exa_domain_filters(options[:domain_filter]))
      body["startPublishedDate"] = recency_start_date(options[:recency_filter]) if options[:recency_filter]

      response = @http_client.post_json(
        EXA_SEARCH_URL,
        body: body,
        headers: { "x-api-key" => key, "Content-Type" => "application/json" }
      )
      raise "Exa API failed with HTTP #{response.code}: #{response.body.to_s[0, 300]}" unless success?(response)

      data = JSON.parse(response.body.to_s)
      records = Array(data["results"])
      results = results_from_exa_records(records, options[:max_results])
      SearchResponse.new(answer: answer_from_results(results), results: results, provider: "exa")
    end

    def results_from_exa_records(records, max_results)
      records.first(max_results).filter_map do |record|
        next unless record.is_a?(Hash)

        url = record["url"].to_s
        next if url.empty?

        text = if record["text"].is_a?(String)
                 record["text"]
               elsif record["highlights"].is_a?(Array)
                 record["highlights"].join(" ")
               else
                 record["snippet"].to_s
               end
        Result.new(
          title: record["title"].to_s.empty? ? url : clean_text(record["title"].to_s),
          url: url,
          excerpt: truncate_text(clean_text(text), MAX_EXCERPT_CHARS),
          provider: "exa"
        )
      end
    end

    def perplexity_search(query, options)
      key = api_key("perplexity")
      raise "Perplexity API key not configured" unless key

      body = {
        "model" => config_value("perplexity_model") || "sonar",
        "messages" => [{ "role" => "user", "content" => query }],
        "max_tokens" => MODEL_PROVIDER_MAX_TOKENS,
        "return_related_questions" => false
      }
      body["search_recency_filter"] = options[:recency_filter] if options[:recency_filter]
      body["search_domain_filter"] = options[:domain_filter].first(20) unless options[:domain_filter].empty?

      response = @http_client.post_json(
        PERPLEXITY_API_URL,
        body: body,
        headers: { "Authorization" => "Bearer #{key}", "Content-Type" => "application/json" }
      )
      raise "Perplexity API failed with HTTP #{response.code}: #{response.body.to_s[0, 300]}" unless success?(response)

      data = JSON.parse(response.body.to_s)
      answer = truncate_text(Array(data["choices"]).first.to_h.dig("message", "content"), MAX_ANSWER_CHARS)
      citations = Array(data["citations"])
      results = citations.first(options[:max_results]).each_with_index.filter_map do |citation, index|
        if citation.is_a?(String)
          Result.new(title: "Source #{index + 1}", url: citation, excerpt: "", provider: "perplexity")
        elsif citation.is_a?(Hash) && citation["url"].to_s != ""
          Result.new(title: citation["title"].to_s.empty? ? "Source #{index + 1}" : citation["title"].to_s, url: citation["url"].to_s, excerpt: truncate_text(citation["snippet"], MAX_EXCERPT_CHARS), provider: "perplexity")
        end
      end
      SearchResponse.new(answer: answer, results: results, provider: "perplexity")
    end

    def gemini_search(query, options)
      key = api_key("gemini")
      raise "Gemini API key not configured" unless key

      prompt = enriched_query(query, options)
      model = config_value("gemini_model") || DEFAULT_GEMINI_MODEL
      response = @http_client.post_json(
        "#{GEMINI_API_BASE}/models/#{CGI.escape(model)}:generateContent?key=#{CGI.escape(key)}",
        body: {
          "contents" => [{ "parts" => [{ "text" => prompt }] }],
          "tools" => [{ "google_search" => {} }]
        },
        headers: { "Content-Type" => "application/json" }
      )
      raise "Gemini API failed with HTTP #{response.code}: #{response.body.to_s[0, 300]}" unless success?(response)

      data = JSON.parse(response.body.to_s)
      candidate = Array(data["candidates"]).first.to_h
      answer = truncate_text(Array(candidate.dig("content", "parts")).map { |part| part.to_h["text"] }.compact.join("\n"), MAX_ANSWER_CHARS)
      chunks = Array(candidate.dig("groundingMetadata", "groundingChunks"))
      results = chunks.first(options[:max_results]).filter_map do |chunk|
        web = chunk.to_h["web"].to_h
        url = web["uri"].to_s
        next if url.empty?

        Result.new(title: web["title"].to_s.empty? ? url : web["title"].to_s, url: url, excerpt: "", provider: "gemini")
      end
      SearchResponse.new(answer: answer, results: results, provider: "gemini")
    end

    def legacy_search(query, options)
      legacy_query = query_with_domain_filter(query, options[:domain_filter])
      results, error = legacy_search_query(legacy_query, options[:max_results], options[:recency_filter])
      raise error if results.empty? && error

      SearchResponse.new(answer: "", results: results, provider: results.first&.provider || "legacy", note: error)
    end

    def legacy_search_query(query, max_results, recency_filter)
      begin
        duckduckgo_results = duckduckgo_search(query, max_results, recency_filter)
        return [duckduckgo_results, nil] unless duckduckgo_results.empty?

        duckduckgo_error = "DuckDuckGo returned no results"
      rescue StandardError => e
        duckduckgo_error = e.message
      end

      searxng_results, searxng_error = searxng_search(query, max_results, recency_filter)
      error = [duckduckgo_error, searxng_error].compact.join("; ")
      [searxng_results, error.empty? ? nil : error]
    end

    def duckduckgo_search(query, max_results, recency_filter)
      form = { "q" => query, "kl" => "wt-wt" }
      form["df"] = duckduckgo_recency(recency_filter) if recency_filter
      response = @http_client.post(
        DUCKDUCKGO_URL,
        form: form,
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

    def searxng_search(query, max_results, recency_filter)
      errors = []

      @searxng_instances.each do |instance|
        begin
          results = searxng_instance_search(instance, query, max_results, recency_filter)
          return [results, nil] unless results.empty?

          errors << "#{instance} returned no results"
        rescue StandardError => e
          errors << "#{instance}: #{e.message}"
        end
      end

      [[], errors.join("; ")]
    end

    def searxng_instance_search(instance, query, max_results, recency_filter)
      begin
        results = searxng_json_search(instance, query, max_results, recency_filter)
        return results unless results.empty?

        json_error = "SearXNG JSON search returned no results"
      rescue StandardError => e
        json_error = e.message
      end

      begin
        results = searxng_html_search(instance, query, max_results, recency_filter)
        return results unless results.empty?

        raise "SearXNG HTML search returned no results"
      rescue StandardError => e
        raise "#{json_error}; #{e.message}"
      end
    end

    def searxng_json_search(instance, query, max_results, recency_filter)
      params = { q: query, format: "json" }
      params[:time_range] = recency_filter if recency_filter
      uri = searxng_search_uri(instance, params)
      response = @http_client.get(uri.to_s, headers: { "Accept" => "application/json" })
      raise "SearXNG search failed with HTTP #{response.code}" unless success?(response)

      data = JSON.parse(response.body.to_s)
      results_from_records(Array(data["results"]), max_results)
    end

    def searxng_html_search(instance, query, max_results, recency_filter)
      params = { q: query }
      params[:time_range] = recency_filter if recency_filter
      uri = searxng_search_uri(instance, params)
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
      excerpt = truncate_text(clean_text((record["content"] || record["snippet"] || record["description"]).to_s), MAX_EXCERPT_CHARS)
      return nil if title.empty? || url.empty?

      Result.new(title: title, url: url, excerpt: excerpt, provider: provider)
    end

    def format_query_results(query, response, error)
      lines = ["## Query: #{query}"]
      fallback_note = [error, response&.note].compact.reject(&:empty?).join("; ")
      lines << "Provider fallback note: #{fallback_note}" if !fallback_note.empty? && successful_response?(response)
      unless successful_response?(response)
        lines << "No results. #{error}"
        return lines.join("\n")
      end

      answer = response.answer.to_s.strip
      unless answer.empty?
        lines << "Provider: #{response.provider}"
        lines << "Answer:"
        lines << answer
      end

      results = response.results || []
      unless results.empty?
        lines << "Sources:" unless answer.empty?
        results.each_with_index do |result, index|
          lines << "#{index + 1}. #{result.title}"
          lines << "   URL: #{result.url}"
          lines << "   Provider: #{result.provider}"
          lines << "   Excerpt: #{result.excerpt}" unless result.excerpt.to_s.empty?
        end
      end
      lines.join("\n")
    end

    def answer_from_results(results)
      results.filter_map do |result|
        excerpt = result.excerpt.to_s.strip
        next if excerpt.empty?

        "#{excerpt}\nSource: #{result.title} (#{result.url})"
      end.join("\n\n")
    end

    def successful_response?(response)
      response && (!response.answer.to_s.strip.empty? || !Array(response.results).empty?)
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

    def truncate_text(text, max_chars)
      value = text.to_s.strip
      return value if value.length <= max_chars

      "#{value[0, max_chars].rstrip}\n... truncated to #{max_chars} characters"
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
        "User-Agent" => "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36",
        "Sec-Fetch-Dest" => "document",
        "Sec-Fetch-Mode" => "navigate",
        "Sec-Fetch-Site" => "none",
        "Sec-Fetch-User" => "?1"
      }
    end

    def truncate_output(output)
      return output if output.bytesize <= @max_output_bytes

      truncated = output.byteslice(0, @max_output_bytes).to_s.scrub
      "#{truncated}\n... truncated to #{@max_output_bytes} bytes"
    end

    def config
      return @config if @config

      @config = ConfigFiles.read_config
    rescue StandardError
      @config = {}
    end

    def web_config
      ConfigFiles.web_search_config(config)
    end

    def config_value(key)
      snake = key.to_s
      camel = snake.gsub(/_([a-z])/) { Regexp.last_match(1).upcase }
      prefixed = "web_search_#{snake}"
      return web_config[snake] if web_config.key?(snake)
      return web_config[camel] if web_config.key?(camel)
      return config[prefixed] if config.key?(prefixed)
      return config[snake] if config.key?(snake)
      return config[camel] if config.key?(camel)

      nil
    end

    def boolean_config_value(key)
      value = config_value(key)
      return value if value == true || value == false

      normalized = value.to_s.strip.downcase
      return true if %w[1 true yes on].include?(normalized)
      return false if %w[0 false no off].include?(normalized)

      nil
    end

    def allow_model_provider_fallback?
      boolean_config_value("allow_model_providers") == true
    end

    def api_key(provider)
      env_name = "#{provider.upcase}_API_KEY"
      value = ENV[env_name].to_s.strip
      return value unless value.empty?

      configured = config_value("#{provider}_api_key").to_s.strip
      configured.empty? ? nil : configured
    end

    def redact_secrets(message)
      redacted = message.to_s.dup
      %w[exa perplexity gemini].each do |provider|
        key = api_key(provider)
        redacted.gsub!(key, "[REDACTED]") if key && !key.empty?
      end
      redacted.gsub!(/key=([^\s&]+)/, "key=[REDACTED]")
      redacted.gsub!(/Bearer\s+[^\s]+/, "Bearer [REDACTED]")
      redacted
    end

    def normalize_provider(value)
      normalized = value.to_s.strip.downcase
      PROVIDERS.include?(normalized) ? normalized : nil
    end

    def normalize_recency(value)
      normalized = value.to_s.strip.downcase
      %w[day week month year].include?(normalized) ? normalized : nil
    end

    def normalize_domain_filter(value)
      Array(value).filter_map do |domain|
        text = domain.to_s.strip
        text.empty? ? nil : text
      end
    end

    def enriched_query(query, options)
      parts = [query_with_domain_filter(query, options[:domain_filter])]
      if options[:recency_filter]
        labels = { "day" => "past 24 hours", "week" => "past week", "month" => "past month", "year" => "past year" }
        parts << labels[options[:recency_filter]]
      end
      parts.join(" ")
    end

    def query_with_domain_filter(query, domain_filter)
      return query if domain_filter.empty?

      terms = domain_filter.map do |domain|
        domain.start_with?("-") ? "-site:#{domain[1..]}" : "site:#{domain}"
      end
      ([query] + terms).join(" ")
    end

    def exa_domain_filters(domain_filter)
      includes = domain_filter.reject { |domain| domain.start_with?("-") }
      excludes = domain_filter.select { |domain| domain.start_with?("-") }.map { |domain| domain[1..] }.reject(&:empty?)
      result = {}
      result["includeDomains"] = includes unless includes.empty?
      result["excludeDomains"] = excludes unless excludes.empty?
      result
    end

    def recency_start_date(filter)
      days = { "day" => 1, "week" => 7, "month" => 30, "year" => 365 }.fetch(filter, 0)
      (Time.now.utc - (days * 86_400)).iso8601
    end

    def duckduckgo_recency(filter)
      { "day" => "d", "week" => "w", "month" => "m", "year" => "y" }[filter]
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

      def post_json(url, body:, headers: {})
        request(url, Net::HTTP::Post, headers: headers) do |http_request|
          http_request.body = JSON.generate(body)
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

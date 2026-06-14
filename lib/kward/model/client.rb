require "json"
require "net/http"
require "uri"
require_relative "../auth/github_oauth"
require_relative "../auth/openai_oauth"
require_relative "../cancellation"
require_relative "../config_files"
require_relative "context_overflow"
require_relative "model_info"
require_relative "payloads"
require_relative "../telemetry/logger"
require_relative "stream_parser"

module Kward
  # Provider-facing model client used by CLI, RPC, compaction, and memory flows.
  #
  # `Client` owns runtime provider selection, credential lookup, retry telemetry,
  # and HTTP requests for the supported model backends. Provider-neutral payload
  # construction and stream parsing live in `ModelPayloads` and
  # `ModelStreamParser`; keep new provider mechanics there when they are reusable,
  # and keep product policy such as configured provider/model selection here.
  class Client
    include ModelPayloads
    OPENROUTER_URL = URI("https://openrouter.ai/api/v1/chat/completions")
    OPENROUTER_MODELS_URL = URI("https://openrouter.ai/api/v1/models")
    CODEX_URL = URI("https://chatgpt.com/backend-api/codex/responses")
    AUTH_ERROR = "No OpenAI OAuth login found. Run `ruby lib/main.rb login`, or set OPENAI_ACCESS_TOKEN/OPENROUTER_API_KEY."
    OPENROUTER_AUTH_ERROR = "No OpenRouter API key found. Set OPENROUTER_API_KEY or add openrouter_api_key to your Kward config."
    COPILOT_AUTH_ERROR = "No GitHub Copilot OAuth login found. Run `ruby lib/main.rb login github` or set COPILOT_GITHUB_TOKEN."
    DEFAULT_OPENAI_MODEL = ModelInfo::DEFAULT_OPENAI_MODEL
    DEFAULT_OPENROUTER_MODEL = ModelInfo::DEFAULT_OPENROUTER_MODEL
    DEFAULT_REASONING_EFFORT = ModelInfo::DEFAULT_REASONING_EFFORT
    RETRY_DELAYS = [1, 2].freeze
    NON_RETRYABLE_PROVIDER_LIMIT_PATTERNS = [
      /GoUsageLimitError/i,
      /FreeUsageLimitError/i,
      /Monthly usage limit reached/i,
      /available balance/i,
      /insufficient[_ ]quota/i,
      /out of (?:budget|credits?)/i,
      /quota exceeded/i,
      /billing/i,
      /payment required/i,
      /(?:usage|spend|credit|quota).*(?:exceeded|reached|exhausted|depleted)/i,
      /(?:exceeded|reached).*(?:usage|quota|credit|budget|balance)/i
    ].freeze

    RequestError = Class.new(StandardError) do
      attr_reader :provider, :code, :body

      def initialize(provider:, code:, body:)
        @provider = provider
        @code = code.to_i
        @body = body.to_s
        super("#{provider} request failed: #{code} #{@body}")
      end

      def context_overflow?
        ContextOverflow.error?(self)
      end

      def transient?
        !context_overflow? && !provider_limit? && (code == 429 || code.between?(500, 599))
      end

      def provider_limit?
        text = [message, body].compact.join("\n")
        Kward::Client::NON_RETRYABLE_PROVIDER_LIMIT_PATTERNS.any? { |pattern| text.match?(pattern) }
      end

      def message_after_attempts(attempts)
        "#{provider} request failed after #{attempts} attempts: #{code} #{body}"
      end
    end
    TRANSIENT_NETWORK_ERRORS = [IOError, EOFError, SystemCallError, Net::OpenTimeout, Net::ReadTimeout].freeze

    def initialize(api_key: ENV["OPENROUTER_API_KEY"], model: nil, openai_access_token: ENV["OPENAI_ACCESS_TOKEN"], oauth: OpenAIOAuth.new, github_oauth: GithubOAuth.new, config_path: OpenAIOAuth.default_config_path, telemetry_logger: TelemetryLogger.new(config_path: config_path))
      @openrouter_api_key = presence(api_key)
      @openai_access_token = presence(openai_access_token)
      @oauth = oauth
      @github_oauth = github_oauth
      @model = model
      @config_path = File.expand_path(config_path)
      @config = load_config
      @telemetry_logger = telemetry_logger
      @copilot_models = nil
      @openrouter_models = nil
      @openrouter_catalog = nil
    end

    def chat(messages, tools: [], on_reasoning_delta: nil, on_assistant_delta: nil, on_retry: nil, cancellation: nil, steering: nil, max_tokens: nil, model: nil, reasoning: nil)
      cancellation&.raise_if_cancelled!
      url, token, provider, account_id = credentials
      raise auth_error_for(provider) if token.nil? || token.empty?

      current_model = model_for(provider, override_model: model)
      current_model = resolved_copilot_chat_model(current_model) if provider == "Copilot" && model.nil?

      validate_image_support!(provider, current_model, messages)
      request_body = JSON.dump(request_body_payload(provider, messages, tools, max_tokens: max_tokens, model: current_model, reasoning: reasoning))
      with_retries(provider, current_model, request_bytes: request_body.bytesize, on_retry: on_retry, cancellation: cancellation) do
        request_started_at = @telemetry_logger.monotonic_now
        message = nil
        status = "completed"
        error = nil
        begin
          message = chat_provider_request(
            provider: provider,
            url: url,
            token: token,
            account_id: account_id,
            messages: messages,
            tools: tools,
            request_body: request_body,
            current_model: current_model,
            on_reasoning_delta: on_reasoning_delta,
            on_assistant_delta: on_assistant_delta,
            cancellation: cancellation,
            max_tokens: max_tokens
          )
        rescue StandardError => e
          status = "failed"
          error = e
          raise e
        ensure
          log_model_request(provider: provider, model: current_model, request_bytes: request_body.bytesize, duration_ms: @telemetry_logger.duration_ms(request_started_at), status: status, error: error, usage: message && (message["usage"] || message[:usage]))
        end
      end
    rescue *TRANSIENT_NETWORK_ERRORS => e
      raise Kward::Cancellation::CancelledError, "cancelled" if cancellation&.cancelled?

      log_error("model_request_error", e)
      raise e
    rescue StandardError => e
      log_error("model_request_error", e)
      raise e
    end

    def current_provider
      _url, _token, provider = credentials
      provider
    rescue StandardError
      label = ModelInfo.provider_label(configured_provider)
      return label unless label.empty?

      openai_configured? ? "Codex" : "OpenRouter"
    end

    def current_model
      current_model_state[:model]
    end

    def current_reasoning_effort
      current_model_state[:reasoning_effort]
    end

    def current_context_window
      state = current_model_state
      ModelInfo.context_window(state[:provider], state[:model])
    end

    # Returns model choices suitable for settings UIs.
    #
    # The active provider may use live catalog data. Inactive providers use static
    # supported choices plus their configured model so listing models does not
    # perform avoidable network calls for every configured credential.
    def available_models
      provider = current_provider
      openai_model = model_for("Codex")
      openrouter_model = model_for("OpenRouter")
      copilot_model = model_for("Copilot")
      openrouter_choices = provider == "OpenRouter" ? openrouter_model_choices : ModelInfo::OPENROUTER_MODEL_CHOICES
      copilot_choices = provider == "Copilot" ? copilot_model_choices : static_copilot_model_choices
      models = ModelInfo::OPENAI_MODEL_CHOICES.map do |id|
        { provider: "Codex", id: id, current: provider == "Codex" && openai_model == id }
      end
      models += openrouter_choices.map do |id|
        { provider: "OpenRouter", id: id, current: provider == "OpenRouter" && openrouter_model == id }
      end
      models += copilot_choices.map do |id|
        { provider: "Copilot", id: id, current: provider == "Copilot" && copilot_model == id }
      end
      models << { provider: "Codex", id: openai_model, current: provider == "Codex" } unless ModelInfo::OPENAI_MODEL_CHOICES.include?(openai_model)
      models << { provider: "OpenRouter", id: openrouter_model, current: provider == "OpenRouter" } unless openrouter_choices.include?(openrouter_model)
      models << { provider: "Copilot", id: copilot_model, current: provider == "Copilot" } unless copilot_choices.include?(copilot_model)
      
      # Sort models by provider, then alphabetically by id
      models.sort_by { |model| [model[:provider], model[:id]] }
    end

    def openrouter_catalog
      fetch_openrouter_models(full_catalog: true).map do |id|
        { provider: "OpenRouter", id: id, current: current_provider == "OpenRouter" && model_for("OpenRouter") == id }
      end.sort_by { |model| model[:id] }
    end

    def current_context_parts(messages, tools)
      build_context_parts(current_provider, messages, tools)
    end

    def supports_in_flight_steer?
      current_provider == "Codex"
    rescue StandardError
      false
    end

    def reload_config
      @config = load_config
      @copilot_models = nil
      @openrouter_models = nil
      @openrouter_catalog = nil
    end

    private

    def current_model_state
      provider = current_provider
      {
        provider: provider,
        model: model_for(provider),
        reasoning_effort: reasoning_effort(provider)
      }
    end

    def chat_provider_request(provider:, url:, token:, account_id:, messages:, tools:, request_body:, current_model:, on_reasoning_delta:, on_assistant_delta:, cancellation:, max_tokens:)
      case provider
      when "Codex"
        chat_codex_provider(
          url: url,
          token: token,
          account_id: account_id,
          messages: messages,
          tools: tools,
          request_body: request_body,
          current_model: current_model,
          on_reasoning_delta: on_reasoning_delta,
          on_assistant_delta: on_assistant_delta,
          cancellation: cancellation,
          max_tokens: max_tokens
        )
      when "Copilot"
        chat_copilot_provider(
          url: url,
          token: token,
          messages: messages,
          tools: tools,
          request_body: request_body,
          current_model: current_model,
          on_assistant_delta: on_assistant_delta,
          cancellation: cancellation
        )
      else
        chat_openrouter_provider(
          url: url,
          token: token,
          request_body: request_body,
          current_model: current_model,
          on_assistant_delta: on_assistant_delta,
          cancellation: cancellation
        )
      end
    end

    def chat_codex_provider(url:, token:, account_id:, messages:, tools:, request_body:, current_model:, on_reasoning_delta:, on_assistant_delta:, cancellation:, max_tokens:)
      message = codex_chat(
        url,
        token,
        account_id,
        messages,
        tools,
        request_body: request_body,
        on_reasoning_delta: on_reasoning_delta,
        on_assistant_delta: on_assistant_delta,
        cancellation: cancellation,
        max_tokens: max_tokens
      )
      attach_response_metadata(message, provider: "Codex", model: current_model)
    end

    def chat_copilot_provider(url:, token:, messages:, tools:, request_body:, current_model:, on_assistant_delta:, cancellation:)
      message = if copilot_responses_model?(current_model)
                  copilot_responses_chat(token, request_body: request_body, on_assistant_delta: on_assistant_delta, cancellation: cancellation)
                else
                  copilot_chat(url, token, messages, tools, request_body: request_body, on_assistant_delta: on_assistant_delta, cancellation: cancellation)
                end
      attach_response_metadata(message, provider: "Copilot", model: current_model)
    end

    def chat_openrouter_provider(url:, token:, request_body:, current_model:, on_assistant_delta:, cancellation:)
      request = Net::HTTP::Post.new(url)
      request["Authorization"] = "Bearer #{token}"
      request["Content-Type"] = "application/json"
      request.body = request_body

      response = Net::HTTP.start(url.hostname, url.port, use_ssl: true) do |http|
        cancellation&.on_cancel { close_http(http) }
        cancellation&.raise_if_cancelled!
        http.request(request)
      end
      cancellation&.raise_if_cancelled!

      unless response.is_a?(Net::HTTPSuccess)
        raise RequestError.new(provider: "OpenRouter", code: response.code, body: response.body)
      end

      body = JSON.parse(response.body)
      message = body.fetch("choices").first.fetch("message")
      cancellation&.raise_if_cancelled!
      on_assistant_delta&.call(message.fetch("content", ""))
      attach_response_metadata(message, provider: "OpenRouter", model: current_model, usage: normalized_usage(body["usage"]))
    end

    def auth_error_for(provider)
      case provider
      when "OpenRouter"
        OPENROUTER_AUTH_ERROR
      when "Copilot"
        COPILOT_AUTH_ERROR
      else
        AUTH_ERROR
      end
    end

    def with_retries(provider, model, request_bytes: nil, on_retry: nil, cancellation: nil)
      attempts = RETRY_DELAYS.length + 1
      attempt = 1

      begin
        cancellation&.raise_if_cancelled!
        yield
      rescue RequestError => e
        raise unless e.transient?
        raise e.message_after_attempts(attempt) if attempt >= attempts

        delay = RETRY_DELAYS[attempt - 1]
        retry_info = { provider: provider, model: model, attempt: attempt + 1, max_attempts: attempts, delay_seconds: delay, error: e.message, request_bytes: request_bytes }
        log_retry(retry_info)
        on_retry&.call(retry_info)
        sleep_with_cancellation(delay, cancellation)
        attempt += 1
        retry
      rescue *TRANSIENT_NETWORK_ERRORS => e
        raise Kward::Cancellation::CancelledError, "cancelled" if cancellation&.cancelled?
        raise "#{provider} request failed after #{attempt} attempts: #{e.message}" if attempt >= attempts

        delay = RETRY_DELAYS[attempt - 1]
        retry_info = { provider: provider, model: model, attempt: attempt + 1, max_attempts: attempts, delay_seconds: delay, error: e.message, request_bytes: request_bytes }
        log_retry(retry_info)
        on_retry&.call(retry_info)
        sleep_with_cancellation(delay, cancellation)
        attempt += 1
        retry
      end
    end

    def log_model_request(provider:, model:, request_bytes:, duration_ms:, status:, error:, usage:)
      payload = {
        "provider" => provider,
        "model" => model,
        "request_bytes" => request_bytes,
        "duration_ms" => duration_ms,
        "status" => status
      }
      if usage.respond_to?(:key?)
        usage_payload = usage.each_with_object({}) { |(key, value), result| result[key.to_s] = value }
        @telemetry_logger.log("tokens", "model_usage", payload.merge("usage" => usage_payload))
      end
      @telemetry_logger.log("performance", "model_request", payload)
    end

    def log_retry(retry_info)
      payload = {
        "provider" => retry_info[:provider],
        "model" => retry_info[:model],
        "attempt" => retry_info[:attempt],
        "max_attempts" => retry_info[:max_attempts],
        "delay_seconds" => retry_info[:delay_seconds],
        "request_bytes" => retry_info[:request_bytes]
      }.merge(TelemetryLogger.error_payload(StandardError.new(retry_info[:error].to_s)))
      @telemetry_logger.log("performance", "model_retry", payload)
      @telemetry_logger.log("errors", "model_retry", payload)
    end

    def log_error(event, error, payload = {})
      return unless error

      @telemetry_logger.log("errors", event, payload.merge(TelemetryLogger.error_payload(error)))
    end

    def sleep_with_cancellation(seconds, cancellation)
      deadline = Time.now + seconds.to_f
      loop do
        cancellation&.raise_if_cancelled!
        remaining = deadline - Time.now
        break if remaining <= 0

        sleep([remaining, 0.1].min)
      end
    end

    def request_body_payload(provider, messages, tools, max_tokens: nil, model: nil, reasoning: nil)
      if provider == "Codex"
        codex_payload(messages, tools, max_tokens: max_tokens, model: model, reasoning: reasoning)
      elsif provider == "Copilot" && copilot_responses_model?(model)
        copilot_responses_payload(messages, tools, max_tokens: max_tokens, model: model, reasoning: reasoning)
      else
        request_payload(provider, messages, tools, max_tokens: max_tokens, model: model, reasoning: reasoning)
      end
    end

    def copilot_responses_model?(model)
      model.to_s.match?(/\Agpt-5(?:\.|-|\z)/)
    end

    def openrouter_model_choices
      live_models = fetch_openrouter_models(full_catalog: false)
      choices = live_models.empty? ? ModelInfo::OPENROUTER_MODEL_CHOICES : live_models
      choices.uniq
    end

    def fetch_openrouter_models(full_catalog: false)
      cache = full_catalog ? @openrouter_catalog : @openrouter_models
      return cache if cache

      token = openrouter_api_key.to_s
      return [] if token.empty? && !full_catalog

      request = Net::HTTP::Get.new(OPENROUTER_MODELS_URL)
      request["Authorization"] = "Bearer #{token}" unless full_catalog || token.empty?
      request["Accept"] = "application/json"

      response = Net::HTTP.start(OPENROUTER_MODELS_URL.hostname, OPENROUTER_MODELS_URL.port, use_ssl: true) { |http| http.request(request) }
      return [] unless response.is_a?(Net::HTTPSuccess)

      models = parse_openrouter_models(response.body)
      if full_catalog
        @openrouter_catalog = models
      else
        @openrouter_models = models
      end
    rescue StandardError
      []
    end

    def parse_openrouter_models(body)
      data = JSON.parse(body.to_s)
      entries = data.is_a?(Hash) ? data["data"] || data["models"] || data["items"] || [] : data
      Array(entries).filter_map do |entry|
        if entry.is_a?(Hash)
          entry["id"] || entry[:id] || entry["slug"] || entry[:slug]
        else
          entry
        end
      end.map(&:to_s).map(&:strip).reject(&:empty?).uniq
    end

    def copilot_model_choices
      live_models = fetch_copilot_models
      return static_copilot_model_choices if live_models.empty?

      supported_copilot_model_choices(live_models)
    end

    def static_copilot_model_choices
      supported_copilot_model_choices(ModelInfo::COPILOT_MODEL_CHOICES)
    end

    def supported_copilot_model_choices(choices)
      choices.select { |model| copilot_supported_model?(model) }.uniq
    end

    def resolved_copilot_chat_model(configured_model)
      choices = fetch_copilot_models
      return configured_model if choices.empty? || choices.include?(configured_model)

      supported = choices.find { |model| copilot_supported_model?(model) }
      raise "No Copilot models supported by Kward are available for this account. Kward currently supports Copilot GPT-5 Responses and Gemini/GPT-4.1 chat models." unless supported

      supported
    end

    def copilot_supported_model?(model)
      text = model.to_s
      copilot_responses_model?(text) || text.match?(/\A(?:gemini-|gpt-4\.1|oswe-)/)
    end

    def fetch_copilot_models
      return @copilot_models if @copilot_models

      token = github_access_token.to_s
      return [] if token.empty?

      url = URI("#{@github_oauth.base_url}/models")
      request = Net::HTTP::Get.new(url)
      request["Authorization"] = "Bearer #{token}"
      request["Accept"] = "application/json"
      copilot_headers([]).each { |key, value| request[key] = value }

      response = Net::HTTP.start(url.hostname, url.port, use_ssl: true) { |http| http.request(request) }
      return [] unless response.is_a?(Net::HTTPSuccess)

      @copilot_models = parse_copilot_models(response.body)
    rescue StandardError
      []
    end

    def parse_copilot_models(body)
      data = JSON.parse(body.to_s)
      entries = data.is_a?(Hash) ? data["data"] || data["models"] || data["items"] || [] : data
      Array(entries).filter_map do |entry|
        copilot_model_id(entry)
      end.uniq
    rescue JSON::ParserError
      []
    end

    def copilot_model_id(entry)
      return entry.to_s.strip unless entry.is_a?(Hash)
      return nil if entry.key?("model_picker_enabled") && entry["model_picker_enabled"] == false

      id = entry["id"] || entry["model"] || entry["name"]
      id.to_s.strip unless id.to_s.strip.empty?
    end

    def copilot_responses_payload(messages, tools, max_tokens: nil, model: nil, reasoning: nil)
      parts = build_context_parts("CopilotResponses", messages, tools, model: model)
      payload = {
        model: parts[:model],
        instructions: parts[:instructions],
        input: parts[:input],
        tools: parts[:tools],
        stream: true,
        store: false
      }
      payload[:reasoning] = { effort: reasoning_effort("Copilot"), summary: "auto" } unless reasoning == false
      payload[:max_output_tokens] = max_tokens.to_i if max_tokens.to_i.positive?
      payload
    end

    def copilot_responses_chat(token, request_body:, on_assistant_delta: nil, cancellation: nil)
      url = URI("#{@github_oauth.base_url}/responses")
      request = Net::HTTP::Post.new(url)
      request["Authorization"] = "Bearer #{token}"
      request["Content-Type"] = "application/json"
      request["Accept"] = "text/event-stream"
      copilot_headers([]).each { |key, value| request[key] = value }
      request.body = request_body

      message = nil
      Net::HTTP.start(url.hostname, url.port, use_ssl: true, read_timeout: nil) do |http|
        cancellation&.on_cancel { close_http(http) }
        cancellation&.raise_if_cancelled!
        http.request(request) do |response|
          unless response.is_a?(Net::HTTPSuccess)
            body = +""
            response.read_body { |chunk| body << chunk }
            raise RequestError.new(provider: "Copilot", code: response.code, body: redact(body, token))
          end

          message = parse_codex_sse_stream(response, on_assistant_delta: on_assistant_delta, cancellation: cancellation)
        end
      end
      cancellation&.raise_if_cancelled!
      message
    end

    def copilot_chat(url, token, messages, tools, request_body: nil, on_assistant_delta: nil, cancellation: nil)
      request = Net::HTTP::Post.new(url)
      request["Authorization"] = "Bearer #{token}"
      request["Content-Type"] = "application/json"
      request["Accept"] = "text/event-stream"
      copilot_headers(messages).each { |key, value| request[key] = value }
      request.body = request_body || JSON.dump(request_payload("Copilot", messages, tools))

      response = Net::HTTP.start(url.hostname, url.port, use_ssl: true, read_timeout: nil) do |http|
        cancellation&.on_cancel { close_http(http) }
        cancellation&.raise_if_cancelled!
        http.request(request)
      end
      cancellation&.raise_if_cancelled!

      unless response.is_a?(Net::HTTPSuccess)
        raise RequestError.new(provider: "Copilot", code: response.code, body: redact(response.body, token))
      end

      parse_openai_chat_sse(response.body.to_s, on_assistant_delta: on_assistant_delta)
    end

    def parse_openai_chat_sse(body, on_assistant_delta: nil)
      ModelStreamParser.parse_openai_chat_sse(body, on_assistant_delta: on_assistant_delta, usage_normalizer: method(:normalized_usage))
    end

    def copilot_headers(messages)
      headers = GithubOAuth::COPILOT_HEADERS.dup
      headers["X-Initiator"] = copilot_initiator(messages)
      headers["Openai-Intent"] = "conversation-edits"
      headers["Copilot-Vision-Request"] = "true" if messages_include_images?(messages)
      headers
    end

    def copilot_initiator(messages)
      last = messages.last || {}
      role = last[:role] || last["role"]
      role.to_s == "user" ? "user" : "agent"
    end

    def codex_chat(url, token, account_id, messages, tools, request_body: nil, on_reasoning_delta: nil, on_assistant_delta: nil, cancellation: nil, max_tokens: nil)
      request = Net::HTTP::Post.new(url)
      request["Authorization"] = "Bearer #{token}"
      request["ChatGPT-Account-Id"] = account_id if account_id
      request["Content-Type"] = "application/json"
      request["Accept"] = "text/event-stream"
      request["originator"] = "codex_cli_rs"
      request.body = request_body || JSON.dump(codex_payload(messages, tools, max_tokens: max_tokens))

      message = nil
      Net::HTTP.start(url.hostname, url.port, use_ssl: true, read_timeout: nil) do |http|
        cancellation&.on_cancel { close_http(http) }
        cancellation&.raise_if_cancelled!
        http.request(request) do |response|
          unless response.is_a?(Net::HTTPSuccess)
            body = +""
            response.read_body { |chunk| body << chunk }
            raise RequestError.new(provider: "Codex", code: response.code, body: redact(body, token))
          end

          message = parse_codex_sse_stream(response, on_reasoning_delta: on_reasoning_delta, on_assistant_delta: on_assistant_delta, cancellation: cancellation)
        end
      end

      cancellation&.raise_if_cancelled!
      message
    rescue *TRANSIENT_NETWORK_ERRORS => e
      raise Kward::Cancellation::CancelledError, "cancelled" if cancellation&.cancelled?

      raise e
    end

    def parse_codex_sse(body, on_reasoning_delta: nil, on_assistant_delta: nil)
      ModelStreamParser.parse_codex_sse(body, on_reasoning_delta: on_reasoning_delta, on_assistant_delta: on_assistant_delta, usage_normalizer: method(:normalized_usage), request_error_class: RequestError)
    end

    def parse_codex_sse_stream(response, on_reasoning_delta: nil, on_assistant_delta: nil, cancellation: nil)
      ModelStreamParser.parse_codex_sse_stream(response, on_reasoning_delta: on_reasoning_delta, on_assistant_delta: on_assistant_delta, cancellation: cancellation, usage_normalizer: method(:normalized_usage), request_error_class: RequestError)
    end

    def close_http(http)
      http.finish if http&.started?
    rescue IOError
      nil
    end

    def attach_response_metadata(message, provider:, model:, usage: nil)
      return message unless message.is_a?(Hash)

      message["provider"] ||= provider
      message["model"] ||= model
      message["usage"] ||= usage if usage
      message
    end

    def normalized_usage(usage)
      return nil unless usage.is_a?(Hash)

      input_tokens = integer_value(usage, "input_tokens", "prompt_tokens")
      output_tokens = integer_value(usage, "output_tokens", "completion_tokens")
      cache_read_tokens = positive_integer(
        nested_value(usage, "input_tokens_details", "cached_tokens") ||
        nested_value(usage, "prompt_tokens_details", "cached_tokens") ||
        usage["cache_read_tokens"] || usage[:cache_read_tokens] || usage["cacheReadTokens"] || usage[:cacheReadTokens]
      )
      cache_write_tokens = integer_value(usage, "cache_write_tokens", "cacheWriteTokens")
      total_tokens = integer_value(usage, "total_tokens", "totalTokens")
      total_tokens ||= [input_tokens, output_tokens, cache_read_tokens, cache_write_tokens].compact.sum
      return nil unless total_tokens&.positive? || input_tokens&.positive? || output_tokens&.positive?

      {
        "input_tokens" => input_tokens || 0,
        "output_tokens" => output_tokens || 0,
        "cache_read_tokens" => cache_read_tokens || 0,
        "cache_write_tokens" => cache_write_tokens || 0,
        "total_tokens" => total_tokens || 0,
        "estimated" => false
      }
    end

    def integer_value(source, *keys)
      return nil unless source.respond_to?(:key?)

      key = keys.find { |candidate| source.key?(candidate) || source.key?(candidate.to_sym) }
      return nil unless key

      positive_integer(source[key] || source[key.to_sym])
    end

    def nested_value(source, outer_key, inner_key)
      outer = source[outer_key] || source[outer_key.to_sym]
      return nil unless outer.respond_to?(:key?)

      outer[inner_key] || outer[inner_key.to_sym]
    end

    def positive_integer(value)
      integer = value.to_i
      integer.positive? ? integer : nil
    end

    def credentials
      provider = ModelInfo.provider_label(configured_provider)
      if provider == "Copilot"
        return [copilot_chat_url, github_access_token, provider, nil]
      end

      if provider == "OpenRouter"
        return [OPENROUTER_URL, openrouter_api_key, provider, nil]
      end

      openai_token = @openai_access_token || @oauth.access_token
      if openai_token
        [CODEX_URL, openai_token, "Codex", @oauth.respond_to?(:account_id) ? @oauth.account_id : nil]
      elsif openrouter_api_key
        [OPENROUTER_URL, openrouter_api_key, "OpenRouter", nil]
      else
        [CODEX_URL, nil, "Codex", nil]
      end
    end

    def model_for(provider, override_model: nil)
      ModelInfo.model_for(provider, config: @config, override_model: override_model || @model)
    end

    def reasoning_effort(provider = nil)
      ModelInfo.reasoning_effort(config: @config, provider: provider)
    end

    def openai_configured?
      !@openai_access_token.to_s.empty? || @oauth.access_token.to_s != ""
    rescue StandardError
      false
    end

    def openrouter_api_key
      @openrouter_api_key || config_value("openrouter_api_key")
    end

    def github_access_token
      @github_oauth.access_token
    end

    def copilot_chat_url
      URI("#{@github_oauth.base_url}/chat/completions")
    end

    def configured_provider
      value = ENV["KWARD_PROVIDER"].to_s.strip
      value = config_value("provider") if value.empty?
      value.to_s.downcase
    end

    def config_value(*keys)
      ConfigFiles.config_value(@config, *keys)
    end

    def load_config
      ConfigFiles.read_config(@config_path)
    end

    def redact(text, token)
      text.to_s.gsub(token.to_s, "[REDACTED]")
    end

    def presence(value)
      text = value.to_s
      text.empty? ? nil : text
    end
  end
end

require "json"
require "net/http"
require "uri"
require_relative "cancellation"
require_relative "config_files"
require_relative "context_overflow"
require_relative "github_oauth"
require_relative "image_attachments"
require_relative "model_info"
require_relative "model_stream_parser"
require_relative "openai_oauth"
require_relative "telemetry_logger"

module Kward
  class Client
    OPENROUTER_URL = URI("https://openrouter.ai/api/v1/chat/completions")
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
        if provider == "Codex"
          message = codex_chat(url, token, account_id, messages, tools, request_body: request_body, on_reasoning_delta: on_reasoning_delta, on_assistant_delta: on_assistant_delta, cancellation: cancellation, max_tokens: max_tokens)
          message = attach_response_metadata(message, provider: provider, model: current_model)
          next message
        end

        if provider == "Copilot"
          message = if copilot_responses_model?(current_model)
                      copilot_responses_chat(token, request_body: request_body, on_assistant_delta: on_assistant_delta, cancellation: cancellation)
                    else
                      copilot_chat(url, token, messages, tools, request_body: request_body, on_assistant_delta: on_assistant_delta, cancellation: cancellation)
                    end
          message = attach_response_metadata(message, provider: provider, model: current_model)
          next message
        end

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
          raise RequestError.new(provider: provider, code: response.code, body: response.body)
        end

        body = JSON.parse(response.body)
        message = body.fetch("choices").first.fetch("message")
        cancellation&.raise_if_cancelled!
        on_assistant_delta&.call(message.fetch("content", ""))
        message = attach_response_metadata(message, provider: provider, model: current_model, usage: normalized_usage(body["usage"]))
        message
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
      return "Copilot" if configured_provider == "copilot"
      return "OpenRouter" if configured_provider == "openrouter"

      openai_configured? ? "Codex" : "OpenRouter"
    end

    def current_model
      model_for(current_provider)
    end

    def current_reasoning_effort
      reasoning_effort
    end

    def current_context_window
      ModelInfo.context_window(current_provider, current_model)
    end

    def available_models
      provider = current_provider
      openai_model = model_for("Codex")
      openrouter_model = model_for("OpenRouter")
      copilot_model = model_for("Copilot")
      copilot_choices = copilot_model_choices
      models = ModelInfo::OPENAI_MODEL_CHOICES.map do |id|
        { provider: "Codex", id: id, current: provider == "Codex" && openai_model == id }
      end
      models += ModelInfo::OPENROUTER_MODEL_CHOICES.map do |id|
        { provider: "OpenRouter", id: id, current: provider == "OpenRouter" && openrouter_model == id }
      end
      models += copilot_choices.map do |id|
        { provider: "Copilot", id: id, current: provider == "Copilot" && copilot_model == id }
      end
      models << { provider: "Codex", id: openai_model, current: provider == "Codex" } unless ModelInfo::OPENAI_MODEL_CHOICES.include?(openai_model)
      models << { provider: "OpenRouter", id: openrouter_model, current: provider == "OpenRouter" } unless ModelInfo::OPENROUTER_MODEL_CHOICES.include?(openrouter_model)
      models << { provider: "Copilot", id: copilot_model, current: provider == "Copilot" } unless copilot_choices.include?(copilot_model)
      models
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
    end

    private

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
        request_payload(provider, messages, tools, max_tokens: max_tokens, model: model)
      end
    end

    def copilot_responses_model?(model)
      model.to_s.match?(/\Agpt-5(?:\.|-|\z)/)
    end

    def copilot_model_choices
      live_models = fetch_copilot_models
      choices = live_models.empty? ? ModelInfo::COPILOT_MODEL_CHOICES : live_models
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
      token = github_access_token.to_s
      return [] if token.empty?

      url = URI("#{@github_oauth.base_url}/models")
      request = Net::HTTP::Get.new(url)
      request["Authorization"] = "Bearer #{token}"
      request["Accept"] = "application/json"
      copilot_headers([]).each { |key, value| request[key] = value }

      response = Net::HTTP.start(url.hostname, url.port, use_ssl: true) { |http| http.request(request) }
      return [] unless response.is_a?(Net::HTTPSuccess)

      parse_copilot_models(response.body)
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
      payload[:reasoning] = { effort: reasoning_effort, summary: "auto" } unless reasoning == false
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

    def merge_streaming_tool_call(tool_calls, delta)
      ModelStreamParser.merge_streaming_tool_call(tool_calls, delta)
    end

    def finalized_streaming_tool_calls(tool_calls)
      ModelStreamParser.finalized_streaming_tool_calls(tool_calls)
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

    def codex_sse_state
      ModelStreamParser.codex_sse_state
    end

    def process_codex_sse_block(block, state, on_reasoning_delta: nil, on_assistant_delta: nil)
      ModelStreamParser.process_codex_sse_block(block, state, on_reasoning_delta: on_reasoning_delta, on_assistant_delta: on_assistant_delta, usage_normalizer: method(:normalized_usage), request_error_class: RequestError)
    end

    def codex_sse_error(event)
      ModelStreamParser.codex_sse_error(event, request_error_class: RequestError)
    end

    def codex_sse_message(state)
      ModelStreamParser.codex_sse_message(state)
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

    def codex_tool_call(item)
      ModelStreamParser.codex_tool_call(item)
    end

    def text_from_codex_items(items)
      ModelStreamParser.text_from_codex_items(items)
    end

    def reasoning_summary_from_codex_items(items)
      ModelStreamParser.reasoning_summary_from_codex_items(items)
    end

    def credentials
      if configured_provider == "copilot"
        return [copilot_chat_url, github_access_token, "Copilot", nil]
      end

      if configured_provider == "openrouter"
        return [OPENROUTER_URL, openrouter_api_key, "OpenRouter", nil]
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

    def request_payload(provider, messages, tools, max_tokens: nil, model: nil)
      parts = build_context_parts(provider, messages, tools, model: model)
      payload = { model: parts[:model], messages: parts[:messages], tools: parts[:tools] }
      payload[:max_tokens] = max_tokens.to_i if max_tokens.to_i.positive?
      payload
    end

    def validate_image_support!(provider, model, messages)
      return if ModelInfo.supports_images?(provider, model)
      return unless messages_include_images?(messages)

      raise "Model '#{model}' does not support image inputs. Switch to a vision-capable model or remove the image attachment."
    end

    def messages_include_images?(messages)
      messages.any? do |message|
        content = message[:content] || message["content"]
        content.is_a?(Array) && content.any? { |part| (part[:type] || part["type"]).to_s == "image" }
      end
    end

    def chat_messages(messages)
      messages.map do |message|
        role = message[:role] || message["role"]
        content = message[:content] || message["content"]
        case role.to_s
        when "compactionSummary"
          { role: "assistant", content: message[:summary] || message["summary"] || content.to_s }
        when "assistant"
          api_message(message, role: "assistant", content: content.is_a?(Array) ? plain_content(content) : content, keys: ["tool_calls", :tool_calls, "name", :name])
        when "toolResult"
          api_message(message, role: "tool", content: plain_content(content).to_s, keys: ["tool_call_id", :tool_call_id, "toolCallId", :toolCallId, "name", :name, "toolName", :toolName])
        when "tool"
          api_message(message, role: "tool", content: plain_content(content).to_s, keys: ["tool_call_id", :tool_call_id, "name", :name])
        when "user"
          api_message(message, role: "user", content: content.is_a?(Array) ? chat_user_content(content) : content, keys: ["name", :name])
        else
          api_message(message, role: role, content: content, keys: ["name", :name])
        end
      end
    end

    def api_message(message, role:, content:, keys: [])
      result = { role: role, content: content }
      keys.each_slice(2) do |string_key, symbol_key|
        value = message[string_key] || message[symbol_key]
        next if value.nil?

        target_key = case string_key.to_s
                     when "toolCallId" then :tool_call_id
                     when "toolName" then :name
                     else string_key.to_sym
                     end
        result[target_key] = value
      end
      result
    end

    def chat_user_content(content)
      content.filter_map do |part|
        type = part[:type] || part["type"]
        if type == "text"
          { type: "text", text: part[:text] || part["text"] || "" }
        elsif type == "image"
          { type: "image_url", image_url: { url: ImageAttachments.data_url(part) } }
        end
      end
    end

    def codex_payload(messages, tools, max_tokens: nil, model: nil, reasoning: nil)
      parts = build_context_parts("Codex", messages, tools, model: model)
      payload = {
        model: parts[:model],
        instructions: parts[:instructions],
        input: parts[:input],
        tools: parts[:tools],
        tool_choice: "auto",
        parallel_tool_calls: false,
        stream: true,
        store: false,
        include: []
      }
      payload[:reasoning] = { effort: reasoning_effort, summary: "auto" } unless reasoning == false
      payload
    end

    def build_context_parts(provider, messages, tools, model: nil)
      if provider == "CopilotResponses"
        instructions, input = codex_messages(messages)
        {
          provider: provider,
          model: model_for("Copilot", override_model: model),
          instructions: instructions.empty? ? "You are a helpful assistant." : instructions,
          input: input,
          tools: tools.map { |tool| codex_tool_schema(tool) }
        }
      elsif provider == "Codex"
        instructions, input = codex_messages(messages)
        {
          provider: provider,
          model: model_for(provider, override_model: model),
          instructions: instructions.empty? ? "You are a helpful assistant." : instructions,
          input: input,
          tools: tools.map { |tool| codex_tool_schema(tool) }
        }
      else
        {
          provider: provider,
          model: model_for(provider, override_model: model),
          messages: chat_messages(messages),
          tools: tools
        }
      end
    end

    def codex_messages(messages)
      instructions = []
      input = []

      messages.each do |message|
        role = message[:role] || message["role"]
        content = message[:content] || message["content"] || ""
        case role.to_s
        when "system"
          instructions << plain_content(content).to_s
        when "tool", "toolResult"
          input << {
            type: "function_call_output",
            call_id: message[:tool_call_id] || message["tool_call_id"] || message[:toolCallId] || message["toolCallId"] || message[:name] || message["name"] || message[:toolName] || message["toolName"] || "tool-call",
            output: plain_content(content).to_s
          }
        when "assistant"
          content = plain_content(content)
          input << codex_message("assistant", content.to_s) unless content.to_s.empty?
          (message[:tool_calls] || message["tool_calls"] || []).each do |tool_call|
            function = tool_call[:function] || tool_call["function"] || {}
            input << {
              type: "function_call",
              call_id: tool_call[:id] || tool_call["id"] || function[:name] || function["name"] || "tool-call",
              name: function[:name] || function["name"],
              arguments: function[:arguments] || function["arguments"] || "{}"
            }
          end
        when "compactionSummary"
          summary = message[:summary] || message["summary"] || content
          input << codex_message("assistant", summary.to_s) unless summary.to_s.empty?
        else
          input << codex_user_message(content)
        end
      end

      [instructions.join("\n\n"), input]
    end

    def codex_user_message(content)
      return codex_message("user", content.to_s) unless content.is_a?(Array)

      parts = content.filter_map do |part|
        type = part[:type] || part["type"]
        if type == "text"
          { type: "input_text", text: part[:text] || part["text"] || "" }
        elsif type == "image"
          { type: "input_image", image_url: ImageAttachments.data_url(part) }
        end
      end
      { type: "message", role: "user", content: parts }
    end

    def codex_message(role, text)
      type = role == "assistant" ? "output_text" : "input_text"
      { type: "message", role: role, content: [{ type: type, text: text }] }
    end

    def plain_content(content)
      return content unless content.is_a?(Array)

      content.filter_map do |part|
        type = part[:type] || part["type"]
        part[:text] || part["text"] if type == "text"
      end.join
    end

    def codex_tool_schema(tool)
      function = tool[:function] || tool["function"] || {}
      {
        type: "function",
        name: function[:name] || function["name"],
        description: function[:description] || function["description"] || "",
        parameters: function[:parameters] || function["parameters"] || {},
        strict: false
      }
    end

    def model_for(provider, override_model: nil)
      ModelInfo.model_for(provider, config: @config, override_model: override_model || @model)
    end

    def reasoning_effort
      ModelInfo.reasoning_effort(config: @config)
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

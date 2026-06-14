require "fileutils"
require "minitest/autorun"
require "stringio"
require "tmpdir"
require_relative "../lib/kward/ansi"
require_relative "../lib/kward/model/client"
require_relative "../lib/kward/conversation"
require_relative "../lib/kward/cli"
require_relative "../lib/kward/plugin_registry"
require_relative "../lib/kward/prompt_interface"
require_relative "../lib/kward/tools/registry"
require_relative "../lib/kward/workspace"

class KwardTestCase < Minitest::Test
  def ask_prompt_with_input(keys)
    input, writer = IO.pipe
    output = StringIO.new
    writer.write(keys)
    writer.close
    prompt = Kward::PromptInterface.new(input: input, output: output)

    prompt.ask("You>")
  ensure
    input&.close unless input&.closed?
  end

  def wait_until(timeout: 1, message: "timed out")
    deadline = Time.now + timeout
    until yield
      raise message if Time.now > deadline

      sleep 0.01
    end
  end

  def poll_prompt_until(prompt, timeout: 1)
    result = nil
    wait_until(timeout: timeout, message: "timed out waiting for prompt input") do
      result = prompt.poll_input
      yield(result)
    end
    result
  end

  def strip_ansi(text)
    Kward::ANSI.strip(text)
  end

  def assert_order(content, *needles)
    previous = -1
    needles.each do |needle|
      index = content.index(needle)
      assert index, "Expected #{needle.inspect} to appear in content"
      assert_operator index, :>, previous, "Expected #{needle.inspect} to appear after previous item"
      previous = index
    end
  end

  def with_env(values)
    previous = {}
    values.each do |key, value|
      previous[key] = ENV[key]
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
    yield
  ensure
    previous.each do |key, value|
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
  end

  def jsonl_records(path)
    File.readlines(path, chomp: true).filter_map do |line|
      JSON.parse(line)
    rescue JSON::ParserError
      nil
    end
  end

  def tool_call(name, args)
    {
      "id" => "call_#{name}",
      "type" => "function",
      "function" => {
        "name" => name,
        "arguments" => JSON.dump(args)
      }
    }
  end

  def assistant_tool_call(name, args)
    { "role" => "assistant", "content" => nil, "tool_calls" => [tool_call(name, args)] }
  end

  def question_args(text)
    {
      question: text,
      header: "Confirm",
      options: [
        { label: "Yes", description: "Continue." },
        { label: "No", description: "Stop." }
      ]
    }
  end

  def fake_response(code, body)
    Kward::WebSearch::NetHttpClient::Response.new(code: code, body: body)
  end

  class FakeHttpClient
    attr_reader :requests

    def initialize(routes)
      @routes = routes
      @requests = []
    end

    def get(url, headers: {})
      request("GET", url, headers: headers)
    end

    def post(url, form:, headers: {})
      request("POST", url, headers: headers, form: form)
    end

    def post_json(url, body:, headers: {})
      request("POST_JSON", url, headers: headers, body: body)
    end

    private

    def request(method, url, headers:, form: nil, body: nil)
      @requests << { method: method, url: url, headers: headers, form: form, body: body }
      response = @routes[[method, url]] || @routes[url]
      raise "unexpected URL: #{method} #{url}" unless response

      response
    end
  end

  class FakeWebSearch
    attr_reader :calls

    def initialize(result)
      @result = result
      @calls = []
    end

    def search(args)
      @calls << args
      @result
    end
  end

  class FakeCodeSearch
    attr_reader :calls

    def initialize(result)
      @result = result
      @calls = []
    end

    def call(args)
      @calls << args
      @result
    end
  end

  def fake_net_response(code, body)
    klass = Net::HTTPResponse::CODE_TO_OBJ.fetch(code.to_s, Net::HTTPUnknownResponse)
    klass.new("1.1", code.to_s, "").tap do |response|
      content = body
      response.define_singleton_method(:body) { content }
      response.define_singleton_method(:read_body) do |&block|
        block.call(content) if block
        content
      end
    end
  end

  class FakeClient
    def initialize(responses)
      @responses = responses
      @provider = "Codex"
      @model = "fake-model"
      @reasoning_effort = "medium"
      @context_window = 200_000
      @reload_count = 0
    end

    attr_accessor :provider, :model, :reasoning_effort, :context_window
    attr_reader :reload_count

    def chat(_messages, tools: [], **_opts)
      @responses.shift
    end

    def current_provider
      @provider
    end

    def current_model
      @model
    end

    def current_reasoning_effort
      @reasoning_effort
    end

    def current_context_window
      @context_window
    end

    def available_models
      [{ provider: @provider, id: @model, contextWindow: @context_window, current: true }]
    end

    def reload_config
      @reload_count += 1
    end
  end

  class FakeOAuth
    def initialize(access_token)
      @access_token = access_token
    end

    attr_reader :access_token
  end

  class FakeAnthropicOAuth
    def initialize(access_token)
      @access_token = access_token
    end

    attr_reader :access_token
  end

  class FakeGithubOAuth
    def initialize(access_token, base_url: "https://api.individual.githubcopilot.com")
      @access_token = access_token
      @base_url = base_url
    end

    attr_reader :access_token, :base_url
  end

  class RecordingClient
    attr_reader :seen_messages

    def initialize(responses)
      @responses = responses
      @seen_messages = []
    end

    def chat(messages, tools: [], **_opts)
      @seen_messages << messages.map(&:dup)
      response = @responses.shift
      response.is_a?(Hash) ? response : { "role" => "assistant", "content" => response }
    end
  end

  class StreamingRecordingClient
    attr_reader :seen_messages

    def initialize(responses)
      @responses = responses
      @seen_messages = []
    end

    def chat(messages, tools: [], on_assistant_delta: nil)
      @seen_messages << messages.map(&:dup)
      content = @responses.shift
      on_assistant_delta&.call(content)
      sleep 0.12
      { "role" => "assistant", "content" => content }
    end
  end

  class SteeringRecordingClient
    attr_reader :seen_messages

    def initialize
      @seen_messages = []
    end

    def supports_in_flight_steer?
      true
    end

    def chat(messages, tools: [], on_assistant_delta: nil, steering: nil)
      @seen_messages << messages.map(&:dup)
      on_assistant_delta&.call("before")
      steering.wait(timeout: 1)
      on_assistant_delta&.call("after")
      { "role" => "assistant", "content" => "beforeafter" }
    end
  end

  class MarkdownStreamingClient
    def initialize(chunks)
      @chunks = chunks
    end

    def chat(_messages, tools: [], on_reasoning_delta: nil, on_assistant_delta: nil)
      @chunks.each { |chunk| on_assistant_delta&.call(chunk) }
      { "role" => "assistant", "content" => @chunks.join }
    end
  end

  class FakePrompt
    attr_reader :output, :redraw_count, :prefilled_inputs

    def initialize(inputs, confirmations: [])
      @inputs = inputs
      @confirmations = confirmations
      @output = []
      @redraw_count = 0
      @prefilled_inputs = []
    end

    def ask(_message)
      @inputs.shift
    end

    def yes?(_message, default: false)
      @confirmations.empty? ? default : @confirmations.shift
    end

    def say(message)
      @output << message
    end

    def redraw
      @redraw_count += 1
    end

    def prefill_input(value)
      @prefilled_inputs << value
    end
  end

  class FakeQuestionPrompt < FakePrompt
    attr_reader :questions

    def initialize(answers)
      super([])
      @answers = answers
      @questions = []
    end

    def ask_user_question(questions)
      @questions << questions
      @answers
    end
  end

  class FakeSelectPrompt < FakePrompt
    attr_reader :select_messages, :select_choices, :select_titles, :select_initial_indices

    def initialize(inputs, confirmations: [])
      super
      @select_messages = []
      @select_choices = []
      @select_titles = []
      @select_initial_indices = []
    end

    def select(message, choices, title: "Sessions", custom: false, initial_index: 0)
      @select_messages << message
      @select_choices << choices
      @select_titles << title
      @select_initial_indices << initial_index
      choices.find { |choice| choice.start_with?("/plan") } || choices.first
    end
  end

  class FakeSettingsPrompt < FakePrompt
    attr_reader :overlay_settings_updates, :select_messages, :select_choices, :select_titles, :select_initial_indices

    def initialize(inputs, selections)
      super(inputs)
      @selections = selections
      @overlay_settings_updates = []
      @select_messages = []
      @select_choices = []
      @select_titles = []
      @select_initial_indices = []
    end

    def select(message, choices, title: "Sessions", custom: false, initial_index: 0)
      @select_messages << message
      @select_choices << choices
      @select_titles << title
      @select_initial_indices << initial_index
      @selections.shift
    end

    def update_overlay_settings(settings)
      @overlay_settings_updates << settings.dup
    end
  end

  class FakeSessionSelectPrompt < FakeSelectPrompt
    def initialize(inputs, selected_text)
      super(inputs)
      @selected_text = selected_text
    end

    def select(message, choices, title: "Sessions", custom: false, initial_index: 0)
      @select_messages << message
      @select_choices << choices
      @select_titles << title
      @select_initial_indices << initial_index
      choices.find { |choice| choice.include?(@selected_text) } || choices.first
    end
  end

  class FakeSessionSelectNoPrefillPrompt < FakeSessionSelectPrompt
    def respond_to?(name, include_private = false)
      return false if name == :prefill_input

      super
    end
  end

  class FakeInput
    def initialize(content, tty:)
      @content = content
      @tty = tty
    end

    def tty?
      @tty
    end

    def read
      @content
    end
  end
end

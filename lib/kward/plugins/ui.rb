require_relative "../deep_copy"
require_relative "../question_contract"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Frontend-neutral structured UI exposed to trusted plugin handlers.
  #
  # Frontends provide a small backend that handles blocking requests and
  # non-blocking events. Unsupported requests fail closed: selection, question,
  # and input return nil, while confirmation returns false.
  class PluginUI
    FEATURES = %i[question select confirm input progress notify].freeze
    NOTIFICATION_LEVELS = %i[info success warning error].freeze
    MAX_TEXT_BYTES = 16_384
    MAX_OPTIONS = 100
    MAX_ID_BYTES = 128

    # Adapts frontend callbacks to the structured plugin UI contract.
    class Backend
      def initialize(capabilities: {}, requester: nil, emitter: nil)
        @capabilities = FEATURES.to_h { |feature| [feature, capability_enabled?(capabilities, feature)] }.freeze
        @requester = requester
        @emitter = emitter
      end

      attr_reader :capabilities

      def supported?(feature)
        @capabilities.fetch(feature.to_sym, false)
      end

      def request(kind, payload, cancellation: nil)
        return nil unless supported?(kind) && @requester

        @requester.call(kind.to_sym, payload, cancellation: cancellation)
      end

      def emit(kind, payload)
        return false unless supported?(kind) && @emitter

        @emitter.call(kind.to_sym, payload)
        true
      end

      private

      def capability_enabled?(capabilities, feature)
        value = capabilities[feature] || capabilities[feature.to_s]
        value.is_a?(Hash) ? value.fetch(:supported, value.fetch("supported", false)) == true : value == true
      end
    end

    def initialize(backend: nil, say_callback: nil, cancellation: nil)
      @backend = backend || Backend.new
      @say_callback = say_callback
      @cancellation = cancellation
    end

    def capabilities
      @backend.capabilities.dup.freeze
    end

    def supported?(feature)
      @backend.supported?(feature)
    end

    def question(questions)
      normalized = QuestionContract.normalize_questions(questions)
      request(:question, questions: normalized)
    end

    def select(title, options, message: nil)
      normalized = normalize_options(options)
      answer = request(
        :select,
        title: required_text(title, "select title"),
        message: optional_text(message),
        options: normalized
      )
      return nil if answer.nil?

      selected = normalized.find { |option| option[:value] == answer.to_s || option[:label] == answer.to_s }
      raise ArgumentError, "plugin UI returned an unknown selection" unless selected

      selected[:value]
    end

    def confirm(title, message = nil, default: false)
      if message.nil?
        message = title
        title = "Confirm"
      end
      answer = request(
        :confirm,
        title: required_text(title, "confirm title"),
        message: required_text(message, "confirm message"),
        default: default == true
      )
      answer == true
    end

    def input(title, placeholder = nil, default: nil)
      answer = request(
        :input,
        title: required_text(title, "input title"),
        placeholder: optional_text(placeholder),
        default: optional_text(default)
      )
      return nil if answer.nil?
      raise ArgumentError, "plugin UI input answer must be a string" unless answer.is_a?(String)

      bounded_text(answer, "input answer")
    end

    def notify(message, level = :info, **options)
      level = options[:level] if options.key?(:level)
      level = level.to_sym
      raise ArgumentError, "unsupported plugin notification level: #{level}" unless NOTIFICATION_LEVELS.include?(level)

      payload = { message: required_text(message, "notification message"), level: level }
      @say_callback&.call(payload[:message]) unless @backend.emit(:notify, immutable(payload))
      nil
    end

    def progress(id = nil, message = nil, percent: nil, done: false, **values)
      id ||= values[:id]
      message ||= values[:message]
      payload = {
        id: required_text(id, "progress id", max_bytes: MAX_ID_BYTES),
        message: required_text(message, "progress message"),
        percent: normalize_percent(percent),
        done: done == true
      }.compact
      unless @backend.emit(:progress, immutable(payload))
        fallback = payload[:percent] ? "#{payload[:message]} (#{payload[:percent]}%)" : payload[:message]
        @say_callback&.call(fallback)
      end
      nil
    end

    def with_cancellation(cancellation)
      self.class.new(backend: @backend, say_callback: @say_callback, cancellation: cancellation)
    end

    private

    def request(kind, payload)
      return false if kind == :confirm && !supported?(kind)
      return nil unless supported?(kind)

      @cancellation&.raise_if_cancelled!
      answer = @backend.request(kind, immutable(payload), cancellation: @cancellation)
      @cancellation&.raise_if_cancelled!
      answer
    end

    def normalize_options(options)
      raise ArgumentError, "select options must be an array" unless options.is_a?(Array)
      unless options.length.between?(1, MAX_OPTIONS)
        raise ArgumentError, "select requires 1-#{MAX_OPTIONS} options"
      end

      normalized = options.map.with_index(1) do |option, index|
        if option.is_a?(Hash)
          label = option[:label] || option["label"]
          value = option.key?(:value) ? option[:value] : option.fetch("value", label)
          description = option[:description] || option["description"]
          {
            label: required_text(label, "select option #{index} label"),
            value: required_text(value, "select option #{index} value"),
            description: optional_text(description)
          }.compact
        else
          text = required_text(option, "select option #{index}")
          { label: text, value: text }
        end
      end
      labels = normalized.map { |option| option[:label] }
      values = normalized.map { |option| option[:value] }
      raise ArgumentError, "select option labels must be unique" unless labels.uniq.length == labels.length
      raise ArgumentError, "select option values must be unique" unless values.uniq.length == values.length

      normalized
    end

    def normalize_percent(percent)
      return nil if percent.nil?

      number = Float(percent)
      raise ArgumentError, "progress percent must be between 0 and 100" unless number.between?(0, 100)

      number % 1 == 0 ? number.to_i : number
    rescue TypeError, ArgumentError
      raise ArgumentError, "progress percent must be between 0 and 100"
    end

    def required_text(value, name, max_bytes: MAX_TEXT_BYTES)
      text = bounded_text(value, name, max_bytes: max_bytes)
      raise ArgumentError, "#{name} is required" if text.strip.empty?

      text
    end

    def optional_text(value)
      value.nil? ? nil : bounded_text(value, "text")
    end

    def bounded_text(value, name, max_bytes: MAX_TEXT_BYTES)
      text = value.to_s
      raise ArgumentError, "#{name} exceeds #{max_bytes} bytes" if text.bytesize > max_bytes

      text.freeze
    end

    def immutable(value)
      DeepCopy.freeze(DeepCopy.dup(value))
    end
  end
end

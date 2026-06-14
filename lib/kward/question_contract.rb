require_relative "message_access"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Validates and normalizes structured clarification questions shared by CLI
  # tools and RPC prompt bridging.
  module QuestionContract
    MIN_QUESTIONS = 1
    MAX_QUESTIONS = 4
    MIN_OPTIONS = 2
    MAX_OPTIONS = 4

    module_function

    def normalize_questions(questions)
      raise ArgumentError, "questions must be an array" unless questions.is_a?(Array)
      unless questions.length.between?(MIN_QUESTIONS, MAX_QUESTIONS)
        raise ArgumentError, "ui/question requires 1-4 questions"
      end

      questions.map.with_index(1) { |question, index| normalize_question(question, index) }
    end

    def normalize_question(question, index)
      raise ArgumentError, "question #{index} must be an object" unless question.is_a?(Hash)
      raise ArgumentError, "question #{index} multiSelect is unsupported" if has_key?(question, :multiSelect)

      text = value(question, :question).to_s.strip
      header = value(question, :header).to_s.strip
      raise ArgumentError, "question #{index} requires question and header" if text.empty? || header.empty?

      options = value(question, :options)
      raise ArgumentError, "question #{index} options must be an array" unless options.is_a?(Array)
      unless options.length.between?(MIN_OPTIONS, MAX_OPTIONS)
        raise ArgumentError, "question #{index} requires 2-4 options"
      end

      {
        question: text,
        header: header,
        options: options.map.with_index(1) { |option, option_index| normalize_option(option, index, option_index) }
      }
    end

    def normalize_option(option, question_index, option_index)
      raise ArgumentError, "question #{question_index} option #{option_index} must be an object" unless option.is_a?(Hash)
      raise ArgumentError, "question #{question_index} preview is unsupported" if has_key?(option, :preview)

      label = value(option, :label).to_s.strip
      description = value(option, :description).to_s.strip
      if label.empty? || description.empty?
        raise ArgumentError, "question #{question_index} option #{option_index} requires label and description"
      end

      { label: label, description: description }
    end

    def value(object, key)
      MessageAccess.value(object, key)
    end

    def has_key?(object, key)
      object.key?(key) || object.key?(key.to_s)
    end
  end
end

require "digest"
require_relative "protocol"

module Kward
  module OpenRouterProxy
    class FakeEmbeddings
      REQUEST_KEYS = %w[model input dimensions encoding_format].freeze
      MAX_DIMENSIONS = 4096
      MAX_INPUTS = 64

      def initialize(models:)
        raise ArgumentError, "fake_embedding_models must be an object" unless models.is_a?(Hash)

        @models = models.each_with_object({}) do |(model, dimensions), configured|
          unless model.is_a?(String) && !model.empty? && dimensions.is_a?(Integer) && dimensions.between?(1, MAX_DIMENSIONS)
            raise ArgumentError, "fake_embedding_models must map model IDs to dimensions between 1 and #{MAX_DIMENSIONS}"
          end

          configured[model] = dimensions
        end.freeze
      end

      def create(value)
        raise RequestError, "Request body must be an object" unless value.is_a?(Hash)

        unsupported = value.keys.map(&:to_s) - REQUEST_KEYS
        raise RequestError, "Unsupported request fields: #{unsupported.join(', ')}" unless unsupported.empty?

        model = value["model"]
        raise RequestError, "A model is required" unless model.is_a?(String) && !model.empty?

        default_dimensions = @models[model]
        raise RequestError, "Fake embedding model is not configured" unless default_dimensions

        dimensions = value.fetch("dimensions", default_dimensions)
        unless dimensions.is_a?(Integer) && dimensions.between?(1, MAX_DIMENSIONS)
          raise RequestError, "dimensions must be an integer between 1 and #{MAX_DIMENSIONS}"
        end

        encoding_format = value.fetch("encoding_format", "float")
        raise RequestError, "Only encoding_format float is supported" unless encoding_format == "float"

        inputs = normalize_input(value["input"])
        if inputs.length > MAX_INPUTS
          raise RequestError, "input must contain no more than #{MAX_INPUTS} items"
        end

        token_count = inputs.sum { |input| input.scan(/\S+/).length }
        {
          object: "list",
          data: inputs.each_with_index.map do |input, index|
            { object: "embedding", embedding: embedding(input, dimensions), index: index }
          end,
          model: model,
          usage: { prompt_tokens: token_count, total_tokens: token_count }
        }
      end

      private

      def normalize_input(input)
        inputs = input.is_a?(Array) ? input : [input]
        unless !inputs.empty? && inputs.all? { |item| item.is_a?(String) }
          raise RequestError, "input must be a string or a non-empty array of strings"
        end

        inputs
      end

      def embedding(text, dimensions)
        vector = Array.new(dimensions, 0.0)
        text.downcase.scan(/[\p{Alnum}]+/u) do |token|
          digest = Digest::SHA256.digest(token)
          index = digest.unpack1("N") % dimensions
          vector[index] += digest.getbyte(4).odd? ? 1.0 : -1.0
        end

        magnitude = Math.sqrt(vector.sum { |value| value * value })
        return vector if magnitude.zero?

        vector.map { |value| value / magnitude }
      end
    end
  end
end

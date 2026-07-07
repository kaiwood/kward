# Namespace for the Kward CLI agent runtime.
module Kward
  # Small recursive copy/freeze helpers for plain Hash/Array payload objects.
  module DeepCopy
    module_function

    def dup(value)
      case value
      when Hash
        value.each_with_object({}) { |(key, item), result| result[key] = dup(item) }
      when Array
        value.map { |item| dup(item) }
      else
        value.dup
      end
    rescue TypeError
      value
    end

    def freeze(value)
      case value
      when Hash
        value.each_value { |item| freeze(item) }
      when Array
        value.each { |item| freeze(item) }
      end
      value.freeze
    end

    def merge(left, right)
      left = dup(left)
      right.each do |key, value|
        left[key] = if left[key].is_a?(Hash) && value.is_a?(Hash)
                      merge(left[key], value)
                    else
                      dup(value)
                    end
      end
      left
    end
  end
end

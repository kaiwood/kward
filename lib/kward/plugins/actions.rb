require "json"
require "shellwords"
require_relative "../deep_copy"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Parses and validates arguments for typed plugin commands and actions.
  # @api private
  class PluginArguments
    PROPERTY_NAME_PATTERN = /\A[A-Za-z0-9][A-Za-z0-9_-]*\z/.freeze
    SUPPORTED_TYPES = %w[string integer number boolean array object].freeze
    BOOLEAN_VALUES = {
      "true" => true,
      "yes" => true,
      "1" => true,
      "false" => false,
      "no" => false,
      "0" => false
    }.freeze

    attr_reader :schema, :positionals

    def initialize(label:, schema:, positionals: [])
      @label = label
      @schema = normalize_schema(schema)
      @properties = @schema.fetch(:properties).to_h { |name, property| [name.to_s, property] }
      @positionals = normalize_positionals(positionals)
      validate_defaults
    end

    def parse(arguments)
      values = case arguments
      when String
        parse_text(arguments)
      when Hash
        normalize_object(arguments)
      when nil
        {}
      else
        raise ArgumentError, "#{@label} arguments must be shell-style text or an object"
      end
      apply_defaults(values)
      validate_required(values)
      validate_object(values)
    end

    private

    def normalize_schema(schema)
      raise ArgumentError, "#{@label} schema must be an object" unless schema.is_a?(Hash)

      normalized = symbolize_keys(DeepCopy.dup(schema))
      type = normalized.fetch(:type, "object").to_s
      raise ArgumentError, "#{@label} schema type must be object" unless type == "object"

      properties = normalized.fetch(:properties, {})
      required = Array(normalized.fetch(:required, [])).map(&:to_s)
      raise ArgumentError, "#{@label} schema properties must be an object" unless properties.is_a?(Hash)
      raise ArgumentError, "#{@label} schema required must be an array" unless normalized.fetch(:required, []).is_a?(Array)
      raise ArgumentError, "#{@label} schema cannot allow additional properties" if normalized[:additionalProperties] == true

      normalized_properties = properties.each_with_object({}) do |(name, property), result|
        name = name.to_s
        raise ArgumentError, "#{@label} property name is invalid: #{name}" unless name.match?(PROPERTY_NAME_PATTERN)
        raise ArgumentError, "#{@label} property #{name} schema must be an object" unless property.is_a?(Hash)
        raise ArgumentError, "#{@label} has duplicate property: #{name}" if result.key?(name.to_sym)

        result[name.to_sym] = normalize_property_schema(name, property)
      end
      unknown_required = required - normalized_properties.keys.map(&:to_s)
      unless unknown_required.empty?
        raise ArgumentError, "#{@label} requires unknown properties: #{unknown_required.join(', ')}"
      end

      normalized[:type] = "object"
      normalized[:properties] = normalized_properties
      normalized[:required] = required
      normalized[:additionalProperties] = false
      DeepCopy.freeze(normalized)
    end

    def normalize_property_schema(name, property)
      property = symbolize_keys(DeepCopy.dup(property))
      type = property.fetch(:type, "string").to_s
      raise ArgumentError, "#{@label} property #{name} has unsupported type: #{type}" unless SUPPORTED_TYPES.include?(type)

      property[:type] = type
      return normalize_schema(property) if type == "object"

      if type == "array"
        items = property.fetch(:items, { type: "string" })
        raise ArgumentError, "#{@label} property #{name} items schema must be an object" unless items.is_a?(Hash)

        items = symbolize_keys(DeepCopy.dup(items))
        item_type = items.fetch(:type, "string").to_s
        unless SUPPORTED_TYPES.include?(item_type) && !%w[array object].include?(item_type)
          raise ArgumentError, "#{@label} property #{name} has unsupported array item type: #{item_type}"
        end
        items[:type] = item_type
        property[:items] = items
      end
      if property.key?(:enum) && !property[:enum].is_a?(Array)
        raise ArgumentError, "#{@label} property #{name} enum must be an array"
      end
      property
    end

    def normalize_positionals(positionals)
      raise ArgumentError, "#{@label} positionals must be an array" unless positionals.is_a?(Array)

      names = positionals.map(&:to_s)
      unknown = names - @properties.keys
      raise ArgumentError, "#{@label} has unknown positional properties: #{unknown.join(', ')}" unless unknown.empty?
      raise ArgumentError, "#{@label} has duplicate positional properties" unless names.uniq.length == names.length

      array_positions = names.each_index.select { |index| property_type(@properties.fetch(names[index])) == "array" }
      if array_positions.any? { |index| index != names.length - 1 }
        raise ArgumentError, "#{@label} array positional must be last"
      end
      names.freeze
    end

    def parse_text(text)
      tokens = Shellwords.shellsplit(text.to_s)
      values = {}
      positional_values = []
      options = true
      index = 0
      while index < tokens.length
        token = tokens[index]
        if options && token == "--"
          options = false
        elsif options && token.start_with?("--")
          index = parse_option(tokens, index, values)
        else
          positional_values << token
        end
        index += 1
      end
      assign_positionals(values, positional_values)
      values
    rescue ArgumentError => error
      raise error if error.message.start_with?(@label)

      raise ArgumentError, "#{@label} arguments are invalid: #{error.message}"
    end

    def parse_option(tokens, index, values)
      raw_option, inline_value = tokens[index].delete_prefix("--").split("=", 2)
      name = property_name_for_option(raw_option)
      negated = name.nil? && raw_option.start_with?("no-")
      option = negated ? raw_option.delete_prefix("no-") : raw_option
      name ||= property_name_for_option(option)
      raise ArgumentError, "#{@label} has unknown option --#{raw_option}" unless name

      property = @properties.fetch(name)
      type = property_type(property)
      if negated
        raise ArgumentError, "#{@label} option --no-#{option} is only valid for booleans" unless type == "boolean"
        raise ArgumentError, "#{@label} option --no-#{option} does not accept a value" if inline_value

        assign_value(values, name, false, property)
        return index
      end

      if type == "boolean" && inline_value.nil?
        following = tokens[index + 1]
        if following && BOOLEAN_VALUES.key?(following.downcase)
          inline_value = following
          index += 1
        else
          assign_value(values, name, true, property)
          return index
        end
      end

      if inline_value.nil?
        index += 1
        raise ArgumentError, "#{@label} option --#{option} requires a value" if index >= tokens.length

        inline_value = tokens[index]
      end
      assign_value(values, name, coerce_text(inline_value, property, name), property)
      index
    end

    def property_name_for_option(option)
      @properties.keys.find { |name| name == option || name.tr("_", "-") == option }
    end

    def assign_positionals(values, tokens)
      remaining = tokens.dup
      @positionals.each do |name|
        next if values.key?(name)
        break if remaining.empty?

        property = @properties.fetch(name)
        if property_type(property) == "array"
          remaining.each { |value| assign_value(values, name, coerce_text(value, property, name), property) }
          remaining.clear
        else
          values[name] = coerce_text(remaining.shift, property, name)
        end
      end
      return if remaining.empty?

      raise ArgumentError, "#{@label} has unexpected positional argument: #{remaining.first}"
    end

    def assign_value(values, name, value, property)
      if property_type(property) == "array"
        values[name] ||= []
        values[name] << value
      elsif values.key?(name)
        raise ArgumentError, "#{@label} option --#{name.tr('_', '-')} may only be provided once"
      else
        values[name] = value
      end
    end

    def coerce_text(value, property, name)
      schema = property_type(property) == "array" ? value_for(property, :items, {}) : property
      type = property_type(schema)
      coerced = case type
      when "string" then value.to_s
      when "integer" then convert_text(type, name) { Integer(value, 10) }
      when "number" then convert_text(type, name) { Float(value) }
      when "boolean"
        BOOLEAN_VALUES.fetch(value.to_s.downcase) do
          raise ArgumentError, "#{@label} argument #{name} must be a boolean"
        end
      when "object"
        convert_text(type, name) do
          parsed = JSON.parse(value)
          raise JSON::ParserError unless parsed.is_a?(Hash)

          parsed
        end
      else
        value
      end
      validate_value(coerced, schema, name)
    end

    def convert_text(type, name)
      yield
    rescue ArgumentError, JSON::ParserError
      raise ArgumentError, "#{@label} argument #{name} must be #{type}"
    end

    def normalize_object(arguments)
      arguments.each_with_object({}) do |(key, value), result|
        name = key.to_s
        raise ArgumentError, "#{@label} has unknown argument: #{name}" unless @properties.key?(name)
        raise ArgumentError, "#{@label} argument was provided more than once: #{name}" if result.key?(name)

        result[name] = value
      end
    end

    def validate_defaults
      @properties.each do |name, property|
        validate_value(value_for(property, :default), property, name) if key?(property, :default)
      end
    end

    def apply_defaults(values)
      @properties.each do |name, property|
        next if values.key?(name) || !key?(property, :default)

        values[name] = DeepCopy.dup(value_for(property, :default))
      end
      values
    end

    def validate_required(values)
      missing = @schema.fetch(:required).reject { |name| values.key?(name) }
      raise ArgumentError, "#{@label} is missing required arguments: #{missing.join(', ')}" unless missing.empty?
    end

    def validate_object(values)
      values.each_with_object({}) do |(name, value), result|
        result[name] = validate_value(value, @properties.fetch(name), name)
      end
    end

    def validate_value(value, property, name)
      type = property_type(property)
      valid = case type
      when "string" then value.is_a?(String)
      when "integer" then value.is_a?(Integer)
      when "number" then value.is_a?(Numeric) && (!value.respond_to?(:finite?) || value.finite?)
      when "boolean" then value == true || value == false
      when "array" then value.is_a?(Array)
      when "object" then value.is_a?(Hash)
      end
      raise ArgumentError, "#{@label} argument #{name} must be #{type}" unless valid

      value = value.map { |item| validate_value(item, value_for(property, :items, {}), name) } if type == "array"
      value = normalize_nested_object(value, property, name) if type == "object"
      enum = value_for(property, :enum)
      if enum && !enum.include?(value)
        raise ArgumentError, "#{@label} argument #{name} must be one of: #{enum.join(', ')}"
      end
      value
    end

    def normalize_nested_object(value, property, name)
      nested_properties = value_for(property, :properties)
      return value.each_with_object({}) { |(key, nested), result| result[key.to_s] = nested } unless nested_properties.is_a?(Hash)

      contract = self.class.new(
        label: "#{@label} argument #{name}",
        schema: {
          type: "object",
          properties: nested_properties,
          required: value_for(property, :required, []),
          additionalProperties: false
        }
      )
      contract.parse(value)
    end

    def property_type(property)
      value_for(property, :type, "string").to_s
    end

    def symbolize_keys(hash)
      hash.each_with_object({}) { |(key, value), result| result[key.to_sym] = value }
    end

    def key?(hash, key)
      hash.key?(key) || hash.key?(key.to_s)
    end

    def value_for(hash, key, default = nil)
      return hash[key] if hash.key?(key)
      return hash[key.to_s] if hash.key?(key.to_s)

      default
    end
  end

  # Structured frontend and RPC result returned by typed commands and actions.
  # @api public
  class PluginResult
    attr_reader :message, :data

    def self.wrap(value)
      return value if value.is_a?(self)
      return new if value.nil?

      new(message: value.to_s)
    end

    def initialize(message: nil, data: nil)
      @message = message.nil? ? nil : message.to_s
      @data = normalize_json(data)
      freeze
    end

    def to_h
      { message: message, data: data }.compact
    end

    private

    def normalize_json(value)
      case value
      when nil, String, Integer, true, false
        value
      when Float
        raise ArgumentError, "Plugin result data must contain finite numbers" unless value.finite?
        value
      when Array
        value.map { |item| normalize_json(item) }.freeze
      when Hash
        value.each_with_object({}) do |(key, item), result|
          unless key.is_a?(String) || key.is_a?(Symbol)
            raise ArgumentError, "Plugin result data keys must be strings or symbols"
          end
          result[key.to_s] = normalize_json(item)
        end.freeze
      else
        raise ArgumentError, "Plugin result data must contain only JSON-compatible values"
      end
    end
  end

  # Registered slash command with optional typed argument parsing.
  # @api public
  class PluginCommand
    attr_reader :name, :description, :argument_hint, :schema, :positionals,
      :plugin_id, :path, :handler

    def initialize(name:, description: "", argument_hint: "", schema: nil, positionals: [], plugin_id: nil, path: nil, handler: nil)
      @name = name
      @description = description
      @argument_hint = argument_hint
      @plugin_id = plugin_id
      @path = path
      @handler = handler
      @arguments = schema && PluginArguments.new(label: "Plugin command /#{name}", schema: schema, positionals: positionals)
      @schema = @arguments&.schema
      @positionals = @arguments&.positionals || [].freeze
      freeze
    end

    def typed?
      !@arguments.nil?
    end

    def parse_arguments(value)
      typed? ? @arguments.parse(value) : value.to_s
    end

    def normalize_result(value)
      typed? ? PluginResult.wrap(value) : value
    end

    def entry
      { name: name, description: description, argument_hint: argument_hint }
    end
  end

  # Registered namespaced action exposed to trusted RPC clients.
  # @api public
  class PluginAction
    attr_reader :id, :name, :plugin_id, :description, :schema, :path, :handler

    def initialize(name:, plugin_id:, description:, schema:, path:, handler:)
      @name = name
      @plugin_id = plugin_id
      @id = "#{plugin_id}/#{name}"
      @description = description
      @path = path
      @handler = handler
      @arguments = PluginArguments.new(label: "Plugin action #{id}", schema: schema)
      @schema = @arguments.schema
      freeze
    end

    def parse_arguments(value)
      raise ArgumentError, "Plugin action #{id} arguments must be an object" unless value.is_a?(Hash)

      @arguments.parse(value)
    end

    def normalize_result(value)
      PluginResult.wrap(value)
    end
  end
end

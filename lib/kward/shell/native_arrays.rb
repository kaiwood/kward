module Kward
  module NativeShell
    module Arrays
      ArrayValue = Struct.new(:associative, :values, keyword_init: true)

      private

      def declare_array(args)
        mode = args.shift
        raise ExecutionError, "declare: use -a for indexed or -A for associative arrays" unless %w[-a -A].include?(mode)
        raise ExecutionError, "declare: expected an array name" if args.empty?
        args.each do |name|
          validate_name(name)
          raise ExecutionError, "#{name}: readonly variable" if @readonly.include?(name)
          existing = @arrays[name]
          associative = mode == "-A"
          raise ExecutionError, "#{name}: cannot change array type" if existing && existing.associative != associative
          values = @variables.key?(name) ? { associative ? "0" : 0 => @variables.delete(name) } : {}
          @arrays[name] ||= ArrayValue.new(associative: associative, values: values)
        end
        0
      end

      def array_index(reference, array)
        value = scalar(reference.subscript)
        if array.associative
          raise ExpansionError, "empty associative array key" if value.empty?
          value
        else
          index = arithmetic_value(value.empty? ? "0" : value).to_i
          index += (array.values.keys.max || -1) + 1 if index.negative?
          raise ExpansionError, "negative array index" if index.negative?
          raise ExpansionError, "array index exceeds limit" if index > 2**31 - 1
          index
        end
      end

      def array_values(reference, keys: false)
        array = @arrays[reference.name]
        unless array
          value = @variables[reference.name]
          return value ? (keys ? ["0"] : [value]) : []
        end
        indices = array.associative ? array.values.keys : array.values.keys.sort
        indices.map { |key| keys ? key.to_s : array.values.fetch(key) }
      end

      def array_read(reference)
        return array_values(reference).join(ifs[0].to_s) if %w[@ *].include?(reference.subscript.literal)
        array = @arrays[reference.name] || ArrayValue.new(associative: false, values: @variables.key?(reference.name) ? { 0 => @variables[reference.name] } : {})
        array.values[array_index(reference, array)]
      end

      def array_store(reference, value)
        validate_name(reference.name)
        raise ExecutionError, "#{reference.name}: readonly variable" if @readonly.include?(reference.name)
        raise ExecutionError, "cannot assign to all array elements" if %w[@ *].include?(reference.subscript.literal)
        array = @arrays[reference.name] ||= ArrayValue.new(associative: false, values: @variables.key?(reference.name) ? { 0 => @variables.delete(reference.name) } : {})
        key = array_index(reference, array)
        array.values[key] = reference.append ? array.values.fetch(key, "") + value : value
      end

      def array_assignment(name, words, append = false)
        raise ExecutionError, "#{name}: readonly variable" if @readonly.include?(name)
        array = @arrays[name] ||= ArrayValue.new(associative: false, values: {})
        @variables.delete(name)
        array.values.clear unless append
        index = append && !array.associative ? (array.values.keys.max || -1) + 1 : 0
        words.each do |word|
          if (element = word.array_element)
            reference, value = element
            reference = Reference.new(name: name, subscript: reference.subscript, append: reference.append)
            key = array_index(reference, array)
            result = scalar(value)
            array.values[key] = reference.append ? array.values.fetch(key, "") + result : result
            index = key + 1 unless array.associative
          else
            raise ExecutionError, "associative array elements require [key]=value" if array.associative
            expand(word).each do |value|
              array.values[index] = value
              index += 1
            end
          end
        end
        0
      end

      def array_fields(reference, quoted, keys: false, values: nil)
        values ||= array_values(reference, keys: keys)
        if reference.subscript.literal == "*" && quoted
          [Fields.characters(values.join(ifs[0].to_s), quoted: true)]
        else
          values.map { |value| Fields.characters(value, quoted: quoted, split: !quoted) }
        end
      end
    end
  end
end

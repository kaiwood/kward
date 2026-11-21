module Kward
  module NativeShell
    # A function sees its caller's active bindings. Save only the names it
    # declares local so other assignments still affect the enclosing shell.
    module Locals
      private

      def local_builtin(args)
        args.shift if args.first == "--"
        raise ExecutionError, "local: expected a name or assignment" if args.empty?

        args.each do |argument|
          name, value = argument.split("=", 2)
          declare_local(name.to_s)
          assign(name, value) if value
        end
        0
      end

      def local_array(name, words)
        array = Arrays::ArrayValue.new(associative: false, values: {})
        populate_array(array, name, words)
        declare_local(name)
        @variables.delete(name)
        @arrays[name] = array
        0
      rescue ExpansionError, ExecutionError => e
        command_error(e, @streams)
      end

      def declare_local(name)
        scope = @local_scopes.last
        raise ExecutionError, "local: only valid in a function" unless scope
        validate_name(name)
        raise ExecutionError, "#{name}: readonly variable" if @readonly.include?(name)
        return if scope.key?(name)

        scope[name] = [@variables.delete(name), @arrays.delete(name), @exported.include?(name),
                       (@line_tracking if name == "LINENO"), (@getopts_index if name == "OPTIND")]
        @command_hash.clear if name == "PATH"
        @getopts_index = nil if name == "OPTIND"
      end

      def restore_locals(scope)
        scope.each do |name, (value, array, exported, line_tracking, getopts_index)|
          value ? @variables[name] = value : @variables.delete(name)
          array ? @arrays[name] = array : @arrays.delete(name)
          exported ? @exported.add(name) : @exported.delete(name)
          @readonly.delete(name)
          @command_hash.clear if name == "PATH"
          @line_tracking = line_tracking if name == "LINENO"
          @getopts_index = getopts_index if name == "OPTIND"
        end
      end
    end
  end
end

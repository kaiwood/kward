require_relative "native_vi"
require_relative "native_line_terminal"

module Kward
  module NativeShell
    class ViTerminal < LineTerminal
      def initialize(runtime)
        super(runtime, ViEditor.new(runtime))
      end

      def read(source, **options)
        super
      rescue ExecutionError, SystemCallError, IOError => e
        @runtime.vi_input_error(e, error: options.fetch(:error))
        ViEditor::Result.new(text: "")
      end
    end
  end
end

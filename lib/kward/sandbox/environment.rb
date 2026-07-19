# Namespace for operating-system command sandboxing.
module Kward
  module Sandbox
    # Builds a minimal environment for sandboxed command workers. In particular,
    # credentials and language-runtime injection variables are not inherited.
    module Environment
      SAFE_VARIABLES = %w[PATH LANG LC_ALL LC_CTYPE TERM COLORTERM NO_COLOR].freeze

      module_function

      def command_worker(temporary_root, source: ENV)
        SAFE_VARIABLES.each_with_object({}) do |name, environment|
          value = source[name].to_s
          environment[name] = value unless value.empty?
        end.merge(
          "HOME" => temporary_root,
          "TMPDIR" => temporary_root,
          "TMP" => temporary_root,
          "TEMP" => temporary_root
        )
      end
    end
  end
end

require "open3"
require "rbconfig"
require "tempfile"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Executes scratchpad buffers and returns transformed buffer content.
  module ScratchpadRunner
    RUBY_END_MARKER_PATTERN = /^__END__\n?/.freeze

    Result = Struct.new(:buffer, :exit_status, keyword_init: true)

    module_function

    def run(language, content)
      case language&.to_sym
      when :ruby
        run_ruby(content)
      else
        raise ArgumentError, "Scratchpad language #{language.inspect} is not runnable"
      end
    end

    def run_ruby(content)
      content = content.to_s
      output, status = capture_ruby_output(content)
      Result.new(buffer: ruby_buffer_with_output(content, output, status.exitstatus), exit_status: status.exitstatus)
    end

    def capture_ruby_output(content)
      Tempfile.create(["kward-scratchpad", ".rb"]) do |file|
        file.write(content)
        file.flush
        Open3.capture2e(RbConfig.ruby, file.path)
      end
    end

    def ruby_buffer_with_output(content, output, exit_status)
      output = output.to_s
      output += "\n" unless output.empty? || output.end_with?("\n")
      output += "[exit status: #{exit_status}]\n" unless exit_status.to_i.zero?

      if (match = content.match(RUBY_END_MARKER_PATTERN))
        "#{content[0...match.begin(0)]}__END__\n#{output}"
      else
        "#{content}#{ruby_end_separator(content)}__END__\n#{output}"
      end
    end

    def ruby_end_separator(content)
      return "" if content.empty?

      content.end_with?("\n") ? "\n" : "\n\n"
    end
  end
end

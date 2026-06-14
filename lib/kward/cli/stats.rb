module Kward
  class CLI
    module Stats
      private

      def export_token_stats(arguments)
        options = parse_token_stats_options(arguments)
        csv = TelemetryStats.new.token_usage_csv(options[:range], bucket: options[:bucket])
        if options[:output]
          File.write(options[:output], csv)
        else
          $stdout.write(csv)
        end
      rescue ArgumentError => e
        warn e.message
        warn "Usage: kward stats tokens [range] [--bucket second|minute|hour|day|week|month|year] [--output path]"
        exit 1
      end

      def parse_token_stats_options(arguments)
        remaining = []
        bucket = nil
        output = nil
        index = 0
        while index < arguments.length
          argument = arguments[index]
          case argument
          when "--bucket"
            index += 1
            raise ArgumentError, "Missing value for --bucket" if index >= arguments.length

            bucket = arguments[index]
          when /\A--bucket=(.+)\z/
            bucket = Regexp.last_match(1)
          when "--output"
            index += 1
            raise ArgumentError, "Missing value for --output" if index >= arguments.length

            output = arguments[index]
          when /\A--output=(.+)\z/
            output = Regexp.last_match(1)
          else
            remaining << argument
          end
          index += 1
        end
        { range: remaining.join(" "), bucket: bucket, output: output }
      end

      def print_stats(argument)
        result = TelemetryStats.new.collect(argument)
        @prompt.say("\n#{colored(assistant_output_prompt, :green, :bold)} #{TelemetryStats.format(result)}\n")
      rescue ArgumentError => e
        message = e.message == TelemetryStats::USAGE ? e.message : "#{e.message}\n#{TelemetryStats::USAGE}"
        @prompt.say("\n#{message}\n")
      end

    end
  end
end

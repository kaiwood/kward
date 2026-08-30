# Namespace for the Kward CLI agent runtime.
module Kward
  # Command-line frontend that coordinates terminal interaction, sessions, tools, and model turns.
  class CLI
    # Compact tool-output summaries for terminal display and restored transcripts.
    module ToolSummaries
      private

      def tool_activity(tool_call)
        "running #{tool_call_name(tool_call).tr("_", " ")}"
      end

      def tool_call_card(tool_call)
        name = tool_call_name(tool_call)
        args = tool_call_args(tool_call)
        title = {
          "read_file" => "Read",
          "write_file" => "Write",
          "edit_file" => "Edit",
          "list_directory" => "List",
          "run_shell_command" => "Run",
          "web_search" => "Search",
          "code_search" => "Code search",
          "fetch_content" => "Fetch",
          "fetch_raw" => "Fetch",
          "read_skill" => "Skill"
        }.fetch(name, name.tr("_", " ").capitalize)
        context = tool_call_card_context(name, args)
        ["◆ #{title}", context].compact.join("  ")
      end

      def tool_call_card_context(name, args)
        value = case name
        when "read_file", "write_file", "edit_file", "list_directory"
          args["path"] || args[:path]
        when "run_shell_command"
          args["command"] || args[:command]
        when "web_search"
          query = Array(args["queries"] || args[:queries]).first
          "“#{query}”" if query
        when "code_search"
          args["query"] || args[:query] || args["package"] || args[:package]
        when "fetch_content", "fetch_raw"
          args["url"] || args[:url]
        when "read_skill"
          args["name"] || args[:name]
        end
        text = value.to_s.gsub(/\s+/, " ").strip
        return nil if text.empty?

        text.length > 80 ? "#{text[0, 79]}…" : text
      end

      def tool_summary_with_duration(summary, elapsed_ms)
        return summary.to_s unless elapsed_ms

        lines = summary.to_s.lines
        first = lines.shift.to_s.chomp
        duration = elapsed_ms < 1_000 ? "#{elapsed_ms.round} ms" : format("%.1f s", elapsed_ms / 1_000.0)
        first = "#{first} · #{duration}"
        lines.empty? ? first : (["#{first}\n"] + lines).join
      end

      def tool_result_summary(tool_call, content)
        name = tool_call_name(tool_call)
        args = tool_call_args(tool_call)
        text = content.to_s
        return error_tool_summary(name, args, text) if tool_result_failed?(text)

        case name
        when "read_file"
          read_file_summary(args, text)
        when "write_file", "edit_file"
          file_change_summary(name, args, text)
        when "run_shell_command"
          shell_command_summary(args, text)
        when "web_search"
          web_search_summary(args, text)
        when "read_skill"
          read_skill_summary(text)
        else
          generic_tool_summary(name, text)
        end
      end

      def tool_result_failed?(content)
        content.to_s.start_with?("Error:", "Declined:", "Cancelled.")
      end

      def limit_tool_output_lines(content, line_limit)
        lines = content.to_s.lines
        return content.to_s if lines.length <= line_limit

        kept_lines = lines.first(line_limit - 1).join
        omitted_lines = lines.length - (line_limit - 1)
        suffix = omitted_lines == 1 ? "line" : "lines"
        notice = "...[truncated #{omitted_lines} #{suffix}]"
        kept_lines.end_with?("\n") || kept_lines.empty? ? "#{kept_lines}#{notice}" : "#{kept_lines}\n#{notice}"
      end

      def read_file_summary(args, content)
        path = args["path"] || args[:path] || "(unknown path)"
        "read_file: #{path}\n#{content.lines.count} lines, #{content.bytesize} bytes"
      end

      def file_change_summary(name, args, content)
        path = args["path"] || args[:path] || path_from_tool_result(content) || "(unknown path)"
        concise = content.lines.first.to_s.strip
        concise = "completed" if concise.empty?
        "#{name}: #{path}\n#{concise}"
      end

      def shell_command_summary(args, content)
        command = args["command"] || args[:command] || ""
        lines = ["run_shell_command: #{command}".strip]
        lines << "Exit status: #{shell_exit_status(content) || "unknown"}"
        stdout = shell_section(content, "STDOUT")
        stderr = shell_section(content, "STDERR")
        lines << compact_stream_summary("stdout", stdout) unless stdout.empty?
        lines << compact_stream_summary("stderr", stderr) unless stderr.empty?
        lines.join("\n")
      end

      def web_search_summary(args, content)
        queries = Array(args["queries"] || args[:queries]).map(&:to_s)
        queries = web_search_queries_from_content(content) if queries.empty?
        counts = web_search_result_counts(content)
        lines = ["web_search"]
        queries.each do |query|
          lines << "#{query}: #{counts.fetch(query, 0)} result(s)"
        end
        lines << "#{web_search_total_count(content)} result(s)" if queries.empty?
        lines.join("\n")
      end

      def read_skill_summary(content)
        "read_skill:\n#{content}"
      end

      def error_tool_summary(name, args, content)
        path = args["path"] || args[:path]
        command = args["command"] || args[:command]
        context = path || command
        [name, context, content.lines.first.to_s.strip].compact.reject(&:empty?).join("\n")
      end

      def generic_tool_summary(name, content)
        text = content.to_s
        return "#{name}: #{text}" if text.length <= RESTORED_TOOL_OUTPUT_LIMIT

        "#{name}: #{text[0, RESTORED_TOOL_OUTPUT_LIMIT]}\n...[truncated #{text.length - RESTORED_TOOL_OUTPUT_LIMIT} bytes]"
      end

      def compact_stream_summary(label, text)
        summary = text.strip
        summary = summary[0, 500] + "\n...[truncated #{summary.length - 500} chars]" if summary.length > 500
        "#{label} (#{text.bytesize} bytes):#{summary.empty? ? "" : "\n#{summary}"}"
      end

      def shell_exit_status(content)
        content.match(/^Exit status: ([^\n]+)/)&.[](1)
      end

      def shell_section(content, name)
        match = content.match(/^#{Regexp.escape(name)}:\n(.*?)(?=\nSTD(?:OUT|ERR):\n|\z)/m)
        match ? match[1] : ""
      end

      def web_search_queries_from_content(content)
        content.scan(/^## Query: (.+)$/).flatten
      end

      def web_search_result_counts(content)
        counts = {}
        current_query = nil
        content.each_line do |line|
          if (match = line.match(/^## Query: (.+)$/))
            current_query = match[1]
            counts[current_query] ||= 0
          elsif current_query && line.match?(/^\d+\. /)
            counts[current_query] += 1
          end
        end
        counts
      end

      def web_search_total_count(content)
        content.each_line.count { |line| line.match?(/^\d+\. /) }
      end

      def path_from_tool_result(content)
        content.match(/\b(?:to|file|Edited)\s+([^:\n]+?)(?:\s|:|\z)/)&.[](1)
      end

      def tool_call_name(tool_call)
        ToolCall.name(tool_call) || "unknown_tool"
      end

      def tool_call_args(tool_call)
        ToolCall.arguments(tool_call)
      end

      def tool_command(tool_call)
        name = tool_call_name(tool_call)
        args = tool_call_args(tool_call)

        if name == "run_shell_command"
          args["command"] || args[:command] || ""
        elsif args.empty?
          name.to_s
        else
          "#{name} #{JSON.dump(args)}"
        end
      end

    end
  end
end

# Namespace for the Kward CLI agent runtime.
module Kward
  # JSON-RPC backend namespace used by UI clients.
  module RPC
    # Normalizes optional client turn context and renders it for model input.
    class TurnContext
      def self.normalize(context)
        new.normalize(context)
      end

      def self.prompt(context)
        new.prompt(context)
      end

      def normalize(context)
        return nil if context.nil?
        raise ArgumentError, "turn context must be an object" unless context.is_a?(Hash)

        active_file = blank_to_nil(value(context, "activeFile"))
        open_files = array_value(context, "openFiles")
        selection = normalize_selection(value(context, "selection"))
        diagnostics = normalize_diagnostics(value(context, "diagnostics"))
        normalized = { active_file: active_file, open_files: open_files, selection: selection, diagnostics: diagnostics }.compact
        normalized.empty? ? nil : normalized
      end

      def prompt(context)
        lines = ["Additional client context:"]
        lines << "- Active file: #{context[:active_file]}" if context[:active_file]
        lines << "- Open files: #{context[:open_files].join(", ")}" if context[:open_files]&.any?
        append_selection(lines, context[:selection]) if context[:selection]
        append_diagnostics(lines, context[:diagnostics])
        lines.join("\n")
      end

      private

      def normalize_selection(selection)
        return nil if selection.nil?
        raise ArgumentError, "context.selection must be an object" unless selection.is_a?(Hash)

        normalized = {
          path: blank_to_nil(value(selection, "path")),
          start_line: integer_or_nil(value(selection, "startLine")),
          end_line: integer_or_nil(value(selection, "endLine")),
          text: blank_to_nil(value(selection, "text"))
        }.compact
        normalized.empty? ? nil : normalized
      end

      def normalize_diagnostics(diagnostics)
        return nil if diagnostics.nil?
        raise ArgumentError, "context.diagnostics must be an array" unless diagnostics.is_a?(Array)

        diagnostics.filter_map do |diagnostic|
          next unless diagnostic.is_a?(Hash)

          {
            path: blank_to_nil(value(diagnostic, "path")),
            line: integer_or_nil(value(diagnostic, "line")),
            severity: blank_to_nil(value(diagnostic, "severity")),
            message: blank_to_nil(value(diagnostic, "message"))
          }.compact
        end
      end

      def append_selection(lines, selection)
        location = [selection[:path], [selection[:start_line], selection[:end_line]].compact.join("-")].compact.reject(&:empty?).join(":")
        lines << "- Selection: #{location}" unless location.empty?
        lines << "```\n#{selection[:text]}\n```" if selection[:text]
      end

      def append_diagnostics(lines, diagnostics)
        Array(diagnostics).each do |diagnostic|
          next if diagnostic.empty?

          location = [diagnostic[:path], diagnostic[:line]].compact.join(":")
          severity = diagnostic[:severity] ? "#{diagnostic[:severity]} " : ""
          lines << "- Diagnostic: #{severity}#{location} #{diagnostic[:message]}".strip
        end
      end

      def array_value(hash, key)
        item = value(hash, key)
        return nil if item.nil?
        raise ArgumentError, "#{key} must be an array" unless item.is_a?(Array)

        item.map(&:to_s).reject(&:empty?)
      end

      def integer_or_nil(item)
        return nil if item.nil? || item.to_s.empty?

        Integer(item)
      rescue ArgumentError, TypeError
        nil
      end

      def blank_to_nil(item)
        item = item.to_s if item.is_a?(Symbol)
        item.to_s.empty? ? nil : item
      end

      def value(hash, key)
        hash[key] || hash[key.to_sym]
      end
    end
  end
end

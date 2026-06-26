require "digest"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Interactive terminal UI used by the CLI frontend.
  class PromptInterface
    # Tracks the on-disk identity and original content for an editor buffer.
    class EditorFileMarker
      attr_reader :content, :digest, :mtime, :size

      def initialize(path:, content:, new_file: false)
        @path = path.to_s
        @content = content.to_s
        @digest = Digest::SHA256.hexdigest(@content)
        refresh unless new_file
      end

      def refresh(content = @content)
        @content = content.to_s
        @digest = Digest::SHA256.hexdigest(@content)
        stat = File.stat(@path)
        @mtime = stat.mtime
        @size = stat.size
      rescue StandardError
        @mtime = nil
        @size = nil
      end

      def changed_on_disk?(new_file: false)
        return false if new_file && !File.exist?(@path)
        return true if new_file && File.exist?(@path)
        return true unless File.exist?(@path)

        File.read(@path) != @content
      rescue StandardError
        true
      end
    end
  end
end

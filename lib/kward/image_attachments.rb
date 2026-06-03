require "base64"
require "cgi"
require "shellwords"
require "uri"

module Kward
  module ImageAttachments
    MAX_IMAGE_BYTES = 20 * 1024 * 1024
    MIME_TYPES = {
      ".gif" => "image/gif",
      ".jpg" => "image/jpeg",
      ".jpeg" => "image/jpeg",
      ".png" => "image/png",
      ".webp" => "image/webp"
    }.freeze
    DATA_URI_PATTERN = %r{data:(image/(?:gif|jpe?g|png|webp));base64,([A-Za-z0-9+/=\r\n]+)}i.freeze
    MARKDOWN_IMAGE_PATTERN = /!\[[^\]]*\]\(([^)]+)\)/.freeze
    DEFAULT_TERMINAL_IMAGE_WIDTH = "40".freeze

    module_function

    def content_from_text(text)
      text = text.to_s
      images = image_parts_from_text(text)
      return text if images.empty?

      [{ type: "text", text: text }] + images
    end

    def image_parts_from_text(text)
      seen = {}
      data_uri_parts(text, seen) + path_parts(text, seen)
    end

    def data_uri_parts(text, seen)
      text.scan(DATA_URI_PATTERN).filter_map do |media_type, data|
        normalized_data = data.gsub(/\s+/, "")
        key = "data:#{media_type.downcase};#{normalized_data}"
        next if seen[key]

        decoded_bytes = Base64.decode64(normalized_data).bytesize
        next if decoded_bytes > MAX_IMAGE_BYTES

        seen[key] = true
        { type: "image", media_type: media_type.downcase.sub("image/jpg", "image/jpeg"), data: normalized_data }
      rescue ArgumentError
        nil
      end
    end

    def path_parts(text, seen)
      image_paths_from_text(text).filter_map do |path|
        expanded_path = expand_image_path(path)
        next unless expanded_path
        next if seen[expanded_path]
        next unless File.file?(expanded_path)
        next if File.size(expanded_path) > MAX_IMAGE_BYTES

        media_type = mime_type(expanded_path)
        next unless media_type

        seen[expanded_path] = true
        {
          type: "image",
          media_type: media_type,
          data: Base64.strict_encode64(File.binread(expanded_path)),
          path: expanded_path
        }
      rescue SystemCallError
        nil
      end
    end

    def image_paths_from_text(text)
      paths = []
      text.scan(MARKDOWN_IMAGE_PATTERN) do |match|
        paths << clean_markdown_path(match.first)
      end

      text.each_line do |line|
        candidate = path_candidate_from_line(line)
        paths << candidate if candidate
        paths.concat(path_tokens_from_line(line))
      end
      paths.compact.uniq
    end

    def path_candidate_from_line(line)
      stripped = line.strip
      return nil if stripped.empty?
      return stripped if stripped.start_with?("file://")

      shell_words = Shellwords.split(stripped)
      return shell_words.first if shell_words.length == 1

      stripped
    rescue ArgumentError
      stripped
    end

    def path_tokens_from_line(line)
      Shellwords.split(line).select { |word| image_extension?(word) || word.start_with?("file://") }
    rescue ArgumentError
      line.scan(/\S+/).select { |word| image_extension?(word) || word.start_with?("file://") }
    end

    def clean_markdown_path(path)
      path.to_s.strip.sub(/\A["']/, "").sub(/["']\z/, "")
    end

    def expand_image_path(path)
      path = clean_markdown_path(path)
      path = file_uri_path(path) if path.start_with?("file://")
      return nil unless image_extension?(path)

      File.expand_path(path)
    end

    def file_uri_path(uri_text)
      uri = URI.parse(uri_text)
      CGI.unescape(uri.path.to_s)
    rescue URI::InvalidURIError
      uri_text.delete_prefix("file://")
    end

    def image_extension?(path)
      MIME_TYPES.key?(File.extname(path.to_s).downcase)
    end

    def mime_type(path)
      MIME_TYPES[File.extname(path.to_s).downcase]
    end

    def data_url(part)
      "data:#{part[:media_type] || part["media_type"]};base64,#{part[:data] || part["data"]}"
    end

    def terminal_image_sequence(part, width: DEFAULT_TERMINAL_IMAGE_WIDTH, env: ENV)
      data = part[:data] || part["data"]
      return nil if data.to_s.empty?

      name = part[:path] || part["path"]
      if iterm_image_protocol?(env)
        iterm_image_sequence(data, name, width)
      else
        kitty_image_sequence(data, name, width)
      end
    end

    def iterm_image_protocol?(env)
      env["TERM_PROGRAM"] == "iTerm.app"
    end

    def iterm_image_sequence(data, name, width)
      params = ["inline=1", "preserveAspectRatio=1", "width=#{width}"]
      params << "name=#{Base64.strict_encode64(File.basename(name))}" if name
      "\e]1337;File=#{params.join(";")}:#{data}\a"
    end

    def kitty_image_sequence(data, name, width)
      params = ["inline=1", "preserveAspectRatio=1", "width=#{width}"]
      params << "name=#{Base64.strict_encode64(File.basename(name))}" if name
      "\e_G#{params.join(";")}:#{data}\e\\"
    end
  end
end

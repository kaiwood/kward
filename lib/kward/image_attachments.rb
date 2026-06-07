require "base64"
require "cgi"
require "shellwords"
require "tmpdir"
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
    EMBEDDED_IMAGE_EXTENSION_PATTERN = /\.(?:gif|jpe?g|png|webp)\b/i.freeze
    DEFAULT_TERMINAL_IMAGE_WIDTH = "40".freeze
    SCREENSHOT_SEARCH_DIRS = ["Desktop", "Downloads", "Pictures"].freeze
    PASTED_IMAGE_BASENAME_PATTERN = /\A(?:screenshot|screen shot|pasted[-_]image)/i.freeze

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

    def extract_references_from_text(text)
      text = text.to_s
      references = references_from_text(text).select { |reference| reference[:status] == :attached }
      { text: display_text_without_references(text, references), attachments: references }
    end

    def display_text_without_references(text, references)
      references.reduce(text.to_s.dup) do |result, reference|
        source = reference[:source_text].to_s
        source.empty? ? result : result.sub(source, "")
      end.gsub(/[ \t]{2,}/, " ").gsub(/[ \t]+\n/, "\n").strip
    end

    def references_from_text(text)
      seen = {}
      refs = data_uri_references(text.to_s, seen)
      image_paths_from_text(text.to_s).each do |path|
        key = "path:#{path}"
        next if seen[key]

        expanded_path = resolve_image_path(path)
        if expanded_path && File.file?(expanded_path)
          next if seen[expanded_path]
          next if File.size(expanded_path) > MAX_IMAGE_BYTES
          next unless mime_type(expanded_path)

          seen[key] = true
          seen[expanded_path] = true
          refs << image_reference(path, expanded_path)
        elsif image_reference_candidate?(path)
          seen[key] = true
          refs << missing_image_reference(path)
        end
      rescue SystemCallError
        seen[key] = true
        refs << missing_image_reference(path)
      end
      refs
    end

    def data_uri_references(text, seen)
      text.scan(DATA_URI_PATTERN).filter_map do |media_type, data|
        source_text = Regexp.last_match[0]
        normalized_data = data.gsub(/\s+/, "")
        key = "data:#{media_type.downcase};#{normalized_data}"
        next if seen[key]

        decoded_bytes = Base64.decode64(normalized_data).bytesize
        next if decoded_bytes > MAX_IMAGE_BYTES

        seen[key] = true
        {
          status: :attached,
          type: "image",
          label: "pasted image",
          media_type: media_type.downcase.sub("image/jpg", "image/jpeg"),
          size_bytes: decoded_bytes,
          source_text: source_text
        }
      rescue ArgumentError
        nil
      end
    end

    def image_reference(original_path, expanded_path)
      {
        status: :attached,
        type: "image",
        label: File.basename(expanded_path),
        media_type: mime_type(expanded_path),
        size_bytes: File.size(expanded_path),
        path: expanded_path,
        original_path: original_path,
        source_text: original_path
      }
    end

    def missing_image_reference(path)
      {
        status: :missing,
        type: "image",
        label: File.basename(clean_markdown_path(path)),
        original_path: path,
        source_text: path
      }
    end

    def image_reference_candidate?(path)
      path = clean_markdown_path(path)
      return false unless image_extension?(path) || path.start_with?("file://")
      return true if path.start_with?("file://", "/", "~/", "./", "../")

      File.basename(path) == path && pasted_image_basename?(path)
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
        expanded_path = resolve_image_path(path)
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
        paths.concat(embedded_image_candidates_from_line(line))
      end
      paths.compact.uniq
    end

    def embedded_image_candidates_from_line(line)
      text = line.to_s
      candidates = []
      text.scan(EMBEDDED_IMAGE_EXTENSION_PATTERN) do
        end_index = Regexp.last_match.end(0)
        embedded_path_start_indexes(text, end_index).each do |start_index|
          candidate = clean_markdown_path(text[start_index...end_index])
          next unless embedded_image_candidate?(candidate)

          candidates << candidate
          break
        end
      end
      candidates
    end

    def embedded_image_candidate?(path)
      image_reference_candidate?(path)
    end

    def embedded_path_start_indexes(text, end_index)
      starts = [0]
      text[0...end_index].scan(/\s+/) { starts << Regexp.last_match.end(0) }
      starts.uniq
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

    def resolve_image_path(path)
      expanded_path = expand_image_path(path)
      return expanded_path if expanded_path && File.file?(expanded_path)

      expand_image_basename(path)
    end

    def expand_image_path(path)
      path = clean_markdown_path(path)
      path = file_uri_path(path) if path.start_with?("file://")
      return nil unless image_extension?(path)

      File.expand_path(path)
    end

    def expand_image_basename(path)
      path = clean_markdown_path(path)
      return nil unless image_extension?(path)
      return nil unless File.basename(path) == path

      current_candidate = File.join(Dir.pwd, path)
      return File.expand_path(current_candidate) if File.file?(current_candidate)
      return nil unless pasted_image_basename?(path)

      screenshot_search_dirs.filter_map do |dir|
        candidate = File.join(dir, path)
        next unless File.file?(candidate)

        File.expand_path(candidate)
      end.first
    end

    def pasted_image_basename?(path)
      File.basename(path).match?(PASTED_IMAGE_BASENAME_PATTERN)
    end

    def screenshot_search_dirs(home: Dir.home, tmpdir: Dir.tmpdir)
      (SCREENSHOT_SEARCH_DIRS.map { |dir| File.join(home, dir) } + [tmpdir]).uniq
    rescue ArgumentError
      []
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
      media_type = part[:mimeType] || part["mimeType"] || part[:media_type] || part["media_type"]
      "data:#{media_type};base64,#{part[:data] || part["data"]}"
    end

    def terminal_image_sequence(part, width: DEFAULT_TERMINAL_IMAGE_WIDTH, env: ENV)
      data = part[:data] || part["data"]
      return nil if data.to_s.empty?

      name = part[:path] || part["path"]
      if iterm_image_protocol?(env)
        iterm_image_sequence(data, name, width)
      elsif kitty_image_protocol?(env)
        kitty_image_sequence(data, name, width)
      end
    end

    def iterm_image_protocol?(env)
      env["TERM_PROGRAM"] == "iTerm.app"
    end

    def kitty_image_protocol?(env)
      env["KITTY_WINDOW_ID"].to_s != "" || env["TERM"].to_s.include?("kitty") || env["TERM_PROGRAM"] == "WezTerm"
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

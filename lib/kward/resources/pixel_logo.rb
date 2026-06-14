require "zlib"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Pixel-art logo data and rendering helpers.
  module PixelLogo
    PNG_SIGNATURE = "\x89PNG\r\n\x1a\n".b.freeze
    TRANSPARENT_ALPHA = 128

    module_function

    def rows_from_png(path, width:, height:)
      rows_from_pixels(indexed_png_pixels(path), width: width, height: height)
    rescue StandardError
      []
    end

    def rows_from_pixels(pixels, width:, height:)
      scaled = scale_pixels(pixels, width: width, height: height)
      render_rows(scaled)
    rescue StandardError
      []
    end

    def half_block_rows_from_png(path, width:, pixel_height:)
      half_block_rows_from_pixels(indexed_png_pixels(path), width: width, pixel_height: pixel_height)
    rescue StandardError
      []
    end

    def half_block_rows_from_pixels(pixels, width:, pixel_height:)
      scaled = scale_pixels(pixels, width: width, height: pixel_height)
      render_half_block_rows(scaled)
    rescue StandardError
      []
    end

    def indexed_png_pixels(path)
      data = File.binread(path)
      raise "Invalid PNG" unless data.start_with?(PNG_SIGNATURE)

      png_width = nil
      png_height = nil
      bit_depth = nil
      color_type = nil
      interlace = nil
      palette = nil
      transparency = []
      idat = +"".b

      each_chunk(data) do |type, chunk|
        case type
        when "IHDR"
          png_width, png_height, bit_depth, color_type, _compression, _filter, interlace = chunk.unpack("NNCCCCC")
        when "PLTE"
          palette = chunk.bytes.each_slice(3).map { |red, green, blue| [red, green, blue, 255] }
        when "tRNS"
          transparency = chunk.bytes
        when "IDAT"
          idat << chunk
        end
      end

      raise "Unsupported PNG" unless png_width && png_height && palette
      raise "Unsupported PNG" unless bit_depth == 8 && color_type == 3 && interlace == 0

      transparency.each_with_index do |alpha, index|
        palette[index] = palette[index][0, 3] + [alpha] if palette[index]
      end

      unfilter_indexed_rows(Zlib::Inflate.inflate(idat), png_width, png_height).map do |row|
        row.map { |index| palette[index] || [0, 0, 0, 0] }
      end
    end

    def each_chunk(data)
      offset = PNG_SIGNATURE.bytesize
      while offset < data.bytesize
        length = data[offset, 4].unpack1("N")
        type = data[offset + 4, 4]
        chunk = data[offset + 8, length]
        yield type, chunk
        offset += length + 12
      end
    end

    def unfilter_indexed_rows(raw, width, height)
      rows = []
      previous = Array.new(width, 0)
      offset = 0

      height.times do
        filter = raw.getbyte(offset)
        offset += 1
        scanline = raw.byteslice(offset, width).bytes
        offset += width
        row = unfilter_scanline(scanline, previous, filter)
        rows << row
        previous = row
      end

      rows
    end

    def unfilter_scanline(scanline, previous, filter)
      row = []
      scanline.each_with_index do |byte, index|
        left = index.zero? ? 0 : row[index - 1]
        up = previous[index] || 0
        up_left = index.zero? ? 0 : previous[index - 1]
        row << case filter
               when 0 then byte
               when 1 then (byte + left) & 0xff
               when 2 then (byte + up) & 0xff
               when 3 then (byte + ((left + up) / 2)) & 0xff
               when 4 then (byte + paeth(left, up, up_left)) & 0xff
               else byte
               end
      end
      row
    end

    def paeth(left, up, up_left)
      estimate = left + up - up_left
      left_distance = (estimate - left).abs
      up_distance = (estimate - up).abs
      up_left_distance = (estimate - up_left).abs
      return left if left_distance <= up_distance && left_distance <= up_left_distance
      return up if up_distance <= up_left_distance

      up_left
    end

    def scale_pixels(pixels, width:, height:)
      source_height = pixels.length
      source_width = pixels.first.length

      height.times.map do |target_y|
        source_y_start = target_y * source_height / height
        source_y_end = [(target_y + 1) * source_height / height, source_y_start + 1].max
        width.times.map do |target_x|
          source_x_start = target_x * source_width / width
          source_x_end = [(target_x + 1) * source_width / width, source_x_start + 1].max
          dominant_color(pixels, source_x_start...source_x_end, source_y_start...source_y_end)
        end
      end
    end

    def dominant_color(pixels, x_range, y_range)
      counts = Hash.new(0)
      y_range.each do |y|
        x_range.each do |x|
          counts[visible_color(pixels[y][x])] += 1
        end
      end
      counts.max_by { |_color, count| count }&.first
    end

    def visible_color(color)
      return nil unless color

      red, green, blue, alpha = color
      return nil if !alpha.nil? && alpha.to_i < TRANSPARENT_ALPHA

      [red, green, blue]
    end

    def render_rows(rows)
      rows.map do |row|
        current = nil
        rendered = +""
        row.each do |color|
          if color != current
            rendered << background_sgr(color)
            current = color
          end
          rendered << " "
        end
        rendered << reset_sgr if current
        rendered
      end
    end

    def render_half_block_rows(rows)
      rows.each_slice(2).map do |top_row, bottom_row|
        bottom_row ||= Array.new(top_row.length)
        current_foreground = nil
        current_background = nil
        rendered = +""
        top_row.each_with_index do |top, index|
          bottom = bottom_row[index]
          foreground, background, glyph = half_block_cell(top, bottom)
          if background != current_background
            rendered << background_sgr(background)
            current_background = background
          end
          if foreground != current_foreground
            rendered << foreground_sgr(foreground)
            current_foreground = foreground
          end
          rendered << glyph
        end
        rendered << reset_sgr if current_foreground || current_background
        rendered
      end
    end

    def half_block_cell(top, bottom)
      if top && bottom
        [top, bottom, "▀"]
      elsif top
        [top, nil, "▀"]
      elsif bottom
        [bottom, nil, "▄"]
      else
        [nil, nil, " "]
      end
    end

    def foreground_sgr(color)
      color ? "\e[38;2;#{color.join(";")}m" : "\e[39m"
    end

    def background_sgr(color)
      color ? "\e[48;2;#{color.join(";")}m" : "\e[49m"
    end

    def reset_sgr
      "\e[0m"
    end
  end
end

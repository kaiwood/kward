require_relative "test_helper"
require_relative "../lib/kward/pixel_logo"

class TestPixelLogo < KwardTestCase
  def test_half_block_rows_from_png_renders_two_pixels_per_terminal_row
    rows = Kward::PixelLogo.half_block_rows_from_png(
      File.expand_path("../lib/kward/resources/avatar_kward_48x48.png", __dir__),
      width: 48,
      pixel_height: 48
    )

    assert_equal 24, rows.length
    assert rows.all? { |row| strip_ansi(row).length == 48 }
    assert rows.any? { |row| row.include?("\e[38;2;") }
    assert rows.any? { |row| row.include?("\e[48;2;") }
    assert rows.any? { |row| row.include?("▀") }
    assert rows.any? { |row| row.include?("▄") }
    assert rows.any? { |row| strip_ansi(row).include?(" ") }
    assert rows.all? { |row| !row.include?("\e_G") }
    assert rows.all? { |row| !row.include?("\e]1337;File=") }
  end

  def test_rows_from_png_returns_empty_rows_for_missing_file
    assert_equal [], Kward::PixelLogo.half_block_rows_from_png("missing.png", width: 8, pixel_height: 4)
  end
end

require_relative "test_helper"
require_relative "../lib/kward/pixel_logo"
require_relative "../lib/kward/resources/avatar_kward_logo"

class TestPixelLogo < KwardTestCase
  def test_half_block_rows_from_pixels_renders_two_pixels_per_terminal_row
    rows = Kward::PixelLogo.half_block_rows_from_pixels(
      Kward::Resources::AvatarKwardLogo::PIXELS,
      width: 32,
      pixel_height: 32
    )

    assert_equal 16, rows.length
    assert rows.all? { |row| strip_ansi(row).length == 32 }
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

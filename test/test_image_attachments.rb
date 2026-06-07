require_relative "test_helper"

class TestImageAttachments < KwardTestCase
  def test_image_parts_from_text_finds_embedded_screenshot_path_with_spaces
    Dir.mktmpdir do |dir|
      path = File.join(dir, "Screenshot 2026-06-07 at 12.34.56.png")
      File.binwrite(path, "png bytes")

      parts = Kward::ImageAttachments.image_parts_from_text("look at #{path}")

      assert_equal 1, parts.length
      assert_equal "image/png", parts.first[:media_type]
      assert_equal Base64.strict_encode64("png bytes"), parts.first[:data]
      assert_equal path, parts.first[:path]
    end
  end

  def test_image_parts_from_text_finds_embedded_screenshot_filename_in_workspace
    Dir.mktmpdir do |dir|
      previous_dir = Dir.pwd
      Dir.chdir(dir) do
        filename = "Screenshot 2026-06-07 at 12.34.56.png"
        File.binwrite(filename, "png bytes")

        parts = Kward::ImageAttachments.image_parts_from_text("look at #{filename}")

        assert_equal 1, parts.length
        assert_equal "image/png", parts.first[:media_type]
        assert_equal File.expand_path(filename), parts.first[:path]
      end
    ensure
      Dir.chdir(previous_dir) if previous_dir
    end
  end

  def test_image_parts_from_text_finds_bare_screenshot_filename_in_home_search_dir
    Dir.mktmpdir do |home|
      desktop = File.join(home, "Desktop")
      FileUtils.mkdir_p(desktop)
      filename = "Screenshot 2026-06-07 at 12.34.56.png"
      path = File.join(desktop, filename)
      File.binwrite(path, "png bytes")

      with_env("HOME" => home) do
        parts = Kward::ImageAttachments.image_parts_from_text("look at #{filename}")

        assert_equal 1, parts.length
        assert_equal "image/png", parts.first[:media_type]
        assert_equal path, parts.first[:path]
      end
    end
  end

  def test_image_parts_from_text_finds_bare_pasted_image_filename_in_tmpdir
    filename = "pasted-image-kward-test-#{Process.pid}.png"
    path = File.join(Dir.tmpdir, filename)
    File.delete(path) if File.exist?(path)

    parts = Kward::ImageAttachments.image_parts_from_text("look at #{filename}")
    assert_empty parts

    File.binwrite(path, "png bytes")
    parts = Kward::ImageAttachments.image_parts_from_text("look at #{filename}")

    assert_equal 1, parts.length
    assert_equal "image/png", parts.first[:media_type]
    assert_equal path, parts.first[:path]
  ensure
    File.delete(path) if path && File.exist?(path)
  end

  def test_terminal_image_sequence_renders_inline_image_escape
    part = { type: "image", media_type: "image/png", data: Base64.strict_encode64("png bytes"), path: "/tmp/pasted.png" }

    sequence = Kward::ImageAttachments.terminal_image_sequence(part, env: {})

    assert_equal "\e_Ginline=1;preserveAspectRatio=1;width=40;name=#{Base64.strict_encode64("pasted.png")}:#{Base64.strict_encode64("png bytes")}\e\\", sequence
  end

  def test_terminal_image_sequence_uses_iterm_protocol_in_iterm
    part = { type: "image", media_type: "image/png", data: Base64.strict_encode64("png bytes"), path: "/tmp/pasted.png" }

    sequence = Kward::ImageAttachments.terminal_image_sequence(part, env: { "TERM_PROGRAM" => "iTerm.app" })

    assert_equal "\e]1337;File=inline=1;preserveAspectRatio=1;width=40;name=#{Base64.strict_encode64("pasted.png")}:#{Base64.strict_encode64("png bytes")}\a", sequence
  end

end

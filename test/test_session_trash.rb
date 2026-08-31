require_relative "test_helper"
require_relative "../lib/kward/sessions/trash"

class TestSessionTrash < KwardTestCase
  def test_delete_uses_available_trash_command
    Dir.mktmpdir do |dir|
      bin_dir = File.join(dir, "bin")
      FileUtils.mkdir_p(bin_dir)
      gio = File.join(bin_dir, "gio")
      File.write(gio, "#!/bin/sh\nexit 0\n")
      File.chmod(0o700, gio)
      session_path = File.join(dir, "session.jsonl")
      File.write(session_path, "{}\n")
      calls = []
      trash = Kward::SessionTrash.new(env: { "PATH" => bin_dir }, host_os: "linux", command_runner: lambda do |command, path|
        calls << [command, path]
        File.delete(path)
        true
      end)

      assert_equal true, trash.delete(session_path)

      refute File.exist?(session_path)
      assert_equal [["gio", "trash"]], calls.map(&:first)
      assert_equal [session_path], calls.map(&:last)
    end
  end

  def test_delete_falls_back_to_file_delete_when_trash_unavailable
    Dir.mktmpdir do |dir|
      session_path = File.join(dir, "session.jsonl")
      File.write(session_path, "{}\n")
      calls = []
      trash = Kward::SessionTrash.new(env: { "PATH" => "" }, host_os: "linux", command_runner: lambda do |command, path|
        calls << [command, path]
        true
      end)

      assert_equal true, trash.delete(session_path)

      refute File.exist?(session_path)
      assert_empty calls
    end
  end
end

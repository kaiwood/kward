require_relative "test_helper"

class TestProjectFiles < KwardTestCase
  def test_non_git_directory_falls_back_to_scanning_without_git_stderr
    Dir.mktmpdir do |directory|
      File.write(File.join(directory, "notes.txt"), "notes")

      stdout, stderr = capture_io do
        assert_equal ["notes.txt"], Kward::ProjectFiles.list(root: directory)
      end

      assert_empty stdout
      assert_empty stderr
    end
  end
end

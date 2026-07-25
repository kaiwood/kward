require_relative "test_helper"

class TestPrivateFile < KwardTestCase
  def test_write_json_replaces_content_with_private_file
    Dir.mktmpdir do |dir|
      path = File.join(dir, "state.json")
      File.write(path, "old content")

      Kward::PrivateFile.write_json(path, "token" => "secret")

      assert_equal({ "token" => "secret" }, JSON.parse(File.read(path)))
      assert_equal 0o600, File.stat(path).mode & 0o777
      assert_empty Dir.glob(File.join(dir, ".state.json.*.tmp"))
    end
  end

  def test_write_json_preserves_existing_content_when_serialization_fails
    Dir.mktmpdir do |dir|
      path = File.join(dir, "state.json")
      File.write(path, "previous content")

      assert_raises(JSON::GeneratorError) do
        Kward::PrivateFile.write_json(path, Float::NAN)
      end

      assert_equal "previous content", File.read(path)
    end
  end
end

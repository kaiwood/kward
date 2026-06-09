require_relative "test_helper"

class TestGithubOAuth < KwardTestCase
  def test_github_oauth_default_auth_path_constructs
    assert_includes Kward::GithubOAuth.new.auth_path, ".kward/github_auth.json"
  end

  def test_github_oauth_save_auth_is_readable_and_private
    Dir.mktmpdir do |dir|
      path = File.join(dir, "github_auth.json")
      oauth = Kward::GithubOAuth.new(auth_path: path)

      oauth.save_auth(tokens: { "github_access_token" => "github-access", "copilot_access_token" => "copilot-access", "copilot_expires_at" => (Time.now.utc + 3600).iso8601 })

      assert_equal "copilot-access", oauth.access_token
      assert_equal 0o600, File.stat(path).mode & 0o777
      assert_equal "github_oauth", JSON.parse(File.read(path)).fetch("auth_mode")
    end
  end

  def test_github_oauth_uses_default_client_id
    Dir.mktmpdir do |dir|
      path = File.join(dir, "missing.json")
      oauth = Kward::GithubOAuth.new(auth_path: File.join(dir, "auth.json"), config_path: path)

      assert_equal Kward::GithubOAuth::DEFAULT_CLIENT_ID, oauth.send(:client_id)
    end
  end

  def test_github_oauth_reads_client_id_from_config
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.json")
      File.write(path, JSON.dump("github_oauth_client_id" => "client-123"))
      oauth = Kward::GithubOAuth.new(auth_path: File.join(dir, "auth.json"), config_path: path)

      assert_equal "client-123", oauth.send(:client_id)
    end
  end
end

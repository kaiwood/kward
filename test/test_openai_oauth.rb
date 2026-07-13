require_relative "test_helper"

class TestOpenAIOAuth < KwardTestCase
  def test_openai_oauth_default_auth_path_constructs
    assert_includes Kward::OpenAIOAuth.new.auth_path, ".kward/auth.json"
  end

  def test_openai_oauth_uses_default_client_id_without_config_file
    Dir.mktmpdir do |dir|
      auth_path = File.join(dir, "auth.json")
      config_path = File.join(dir, "missing_kward_config.json")
      oauth = Kward::OpenAIOAuth.new(auth_path: auth_path, config_path: config_path)
      url = URI.parse(oauth.authorization_url(
        redirect_uri: "http://localhost:1455/auth/callback",
        code_challenge: "challenge",
        state: "state-123"
      ))
      params = URI.decode_www_form(url.query).to_h

      assert_equal Kward::OpenAIOAuth::DEFAULT_CLIENT_ID, params["client_id"]
    end
  end

  def test_openai_oauth_authorization_url_includes_configured_client_id_pkce_and_state
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.json")
      File.write(path, JSON.dump("openai_oauth_client_id" => "configured-client"))
      oauth = Kward::OpenAIOAuth.new(auth_path: File.join(dir, "auth.json"), config_path: path)
      url = URI.parse(oauth.authorization_url(
        redirect_uri: "http://localhost:1455/auth/callback",
        code_challenge: "challenge",
        state: "state-123"
      ))
      params = URI.decode_www_form(url.query).to_h

      assert_equal "https", url.scheme
      assert_equal "auth.openai.com", url.host
      assert_equal "code", params["response_type"]
      assert_equal "configured-client", params["client_id"]
      assert_equal "challenge", params["code_challenge"]
      assert_equal "S256", params["code_challenge_method"]
      assert_equal "state-123", params["state"]
    end
  end

  def test_openai_oauth_save_auth_is_readable_by_client_and_private
    Dir.mktmpdir do |dir|
      path = File.join(dir, "auth.json")
      oauth = Kward::OpenAIOAuth.new(auth_path: path)

      oauth.save_auth(tokens: { "access_token" => "oauth-access", "refresh_token" => "refresh", "expires_in" => 3600 })

      assert_equal "oauth-access", oauth.access_token
      assert_equal 0o600, File.stat(path).mode & 0o777
    end
  end

  def test_openai_oauth_refresh_posts_keyword_params
    Dir.mktmpdir do |dir|
      path = File.join(dir, "auth.json")
      oauth = Kward::OpenAIOAuth.new(auth_path: path, client_id: "client", config_path: "missing_config.json")
      oauth.save_auth(tokens: { "access_token" => "old", "refresh_token" => "refresh", "expires_at" => (Time.now.utc - 60).iso8601 })
      posted = nil
      response = Net::HTTPOK.new("1.1", "200", "OK")
      response.instance_variable_set(:@read, true)
      response.body = JSON.dump("access_token" => "new", "expires_in" => 3600)
      http = Object.new
      http.define_singleton_method(:request) do |request|
        posted = JSON.parse(request.body)
        response
      end

      original_start = Net::HTTP.method(:start)
      Net::HTTP.define_singleton_method(:start) { |_host, _port, use_ssl:, &block| block.call(http) }
      assert_equal "new", oauth.access_token
      assert_equal "refresh_token", posted["grant_type"]
      assert_equal "client", posted["client_id"]
      assert_equal "refresh", posted["refresh_token"]
    ensure
      Net::HTTP.define_singleton_method(:start, original_start) if original_start
    end
  end

  def test_openai_oauth_rejects_missing_state_when_expected
    Dir.mktmpdir do |dir|
      oauth = Kward::OpenAIOAuth.new(auth_path: File.join(dir, "auth.json"))

      assert_raises(RuntimeError) do
        oauth.authorization_code_from("http://localhost:1455/auth/callback?code=abc", expected_state: "right")
      end
    end
  end

  def test_openai_oauth_rejects_state_mismatch
    Dir.mktmpdir do |dir|
      oauth = Kward::OpenAIOAuth.new(auth_path: File.join(dir, "auth.json"))

      assert_raises(RuntimeError) do
        oauth.authorization_code_from("http://localhost:1455/auth/callback?code=abc&state=wrong", expected_state: "right")
      end
    end
  end

end

require_relative "test_helper"

class TestAnthropicOAuth < KwardTestCase
  def test_authorization_url_uses_pkce_and_subscription_scope
    oauth = Kward::AnthropicOAuth.new(auth_path: "missing.json", client_id: "client", config_path: "missing_config.json")

    url = oauth.authorization_url(redirect_uri: "http://localhost/callback", code_challenge: "challenge", state: "state")
    params = URI.decode_www_form(URI.parse(url).query).to_h

    assert_equal "https://claude.ai/oauth/authorize", "#{URI.parse(url).scheme}://#{URI.parse(url).host}#{URI.parse(url).path}"
    assert_equal "client", params["client_id"]
    assert_equal "code", params["response_type"]
    assert_equal "challenge", params["code_challenge"]
    assert_equal "S256", params["code_challenge_method"]
    assert_includes params["scope"], "user:inference"
    assert_includes params["scope"], "user:sessions:claude_code"
  end

  def test_authorization_code_from_callback_validates_state
    oauth = Kward::AnthropicOAuth.new(auth_path: "missing.json", client_id: "client", config_path: "missing_config.json")

    assert_equal "abc", oauth.authorization_code_from("http://localhost/callback?code=abc&state=ok", expected_state: "ok")
    assert_equal "abc", oauth.authorization_code_from("abc#ok", expected_state: "ok")
    assert_raises(RuntimeError) { oauth.authorization_code_from("http://localhost/callback?code=abc&state=bad", expected_state: "ok") }
  end

  def test_save_auth_writes_private_file_shape
    Dir.mktmpdir do |dir|
      path = File.join(dir, "anthropic_auth.json")
      oauth = Kward::AnthropicOAuth.new(auth_path: path, client_id: "client", config_path: "missing_config.json")

      oauth.save_auth(tokens: { "access_token" => "access", "refresh_token" => "refresh", "expires_in" => 3600 })
      data = JSON.parse(File.read(path))

      assert_equal "anthropic_oauth", data.fetch("auth_mode")
      assert_equal "access", data.dig("tokens", "access_token")
      assert data["expires_at"]
    end
  end
end

require_relative "test_helper"

class TestOpenAIOAuth < KwardTestCase
  def test_openai_oauth_default_auth_path_constructs
    assert_includes Kward::OpenAIOAuth.new.auth_path, ".kward/auth.json"
  end

  def test_openai_oauth_requires_external_config_file_for_client_id
    oauth = Kward::OpenAIOAuth.new(auth_path: "tmp_auth.json", config_path: "missing_kward_config.json")

    error = assert_raises(RuntimeError) do
      oauth.authorization_url(redirect_uri: "http://localhost:1455/auth/callback", code_challenge: "challenge", state: "state-123")
    end

    assert_equal "Kward config not found: #{File.expand_path("missing_kward_config.json")}", error.message
  end

  def test_openai_oauth_authorization_url_includes_configured_client_id_pkce_and_state
    path = "kward_test_config.json"
    File.write(path, JSON.dump("openai_oauth_client_id" => "configured-client"))
    oauth = Kward::OpenAIOAuth.new(auth_path: "tmp_auth.json", config_path: path)
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
  ensure
    File.delete(path) if path && File.exist?(path)
  end

  def test_openai_oauth_save_auth_is_readable_by_client_and_private
    path = "kward_test_auth.json"
    oauth = Kward::OpenAIOAuth.new(auth_path: path)

    oauth.save_auth(tokens: { "access_token" => "oauth-access", "refresh_token" => "refresh", "expires_in" => 3600 })

    assert_equal "oauth-access", oauth.access_token
    assert_equal 0o600, File.stat(path).mode & 0o777
  ensure
    File.delete(path) if path && File.exist?(path)
  end

  def test_openai_oauth_rejects_state_mismatch
    oauth = Kward::OpenAIOAuth.new(auth_path: "tmp_auth.json")

    assert_raises(RuntimeError) do
      oauth.authorization_code_from("http://localhost:1455/auth/callback?code=abc&state=wrong", expected_state: "right")
    end
  end

end

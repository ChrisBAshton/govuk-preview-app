require "rails_helper"

RSpec.describe "OAuth provider for previewed apps" do
  let(:user) { create(:user, uid: "user-uid", name: "Jo Previewer", email: "jo@example.com") }
  let(:preview) { create(:preview, app_name: "frontend", branch: "my-branch", status: :running) }
  let(:redirect_uri) { "#{preview.url}/auth/gds/callback" }
  let(:code_verifier) { "a" * 64 }
  let(:code_challenge) { PreviewSignon.challenge_for(code_verifier) }

  def authorize_params(overrides = {})
    {
      client_id: preview.app_name,
      redirect_uri: redirect_uri,
      code_challenge: code_challenge,
      code_challenge_method: "S256",
      state: "xyz",
    }.merge(overrides)
  end

  def basic_auth_header(client_id, secret)
    { "HTTP_AUTHORIZATION" => ActionController::HttpAuthentication::Basic.encode_credentials(client_id, secret) }
  end

  def code_from_redirect
    URI.decode_www_form(URI.parse(response.headers["Location"]).query).to_h["code"]
  end

  describe "GET /oauth/authorize" do
    it "issues a code and redirects back to redirect_uri, once signed in" do
      login_as(user)

      get "/oauth/authorize", params: authorize_params

      expect(response).to redirect_to(a_string_starting_with(redirect_uri))
      params = URI.decode_www_form(URI.parse(response.headers["Location"]).query).to_h
      expect(params["code"]).to be_present
      expect(params["state"]).to eq("xyz")
    end

    it "rejects a redirect_uri that isn't a real, running preview's callback" do
      login_as(user)

      get "/oauth/authorize", params: authorize_params(redirect_uri: "https://evil.example.com/auth/gds/callback")

      expect(response).to have_http_status(:bad_request)
    end

    it "rejects a redirect_uri for a preview that isn't routable (e.g. still being built)" do
      preview.update!(status: :starting)
      login_as(user)

      get "/oauth/authorize", params: authorize_params

      expect(response).to have_http_status(:bad_request)
    end

    it "rejects an unknown app name as client_id" do
      login_as(user)

      get "/oauth/authorize", params: authorize_params(client_id: "not-a-real-app")

      expect(response).to have_http_status(:bad_request)
    end

    it "rejects a request missing a PKCE code_challenge" do
      login_as(user)

      get "/oauth/authorize", params: authorize_params(code_challenge: "")

      expect(response).to have_http_status(:bad_request)
    end
  end

  describe "POST /oauth/access_token and GET /user.json" do
    def issued_code
      login_as(user)
      get "/oauth/authorize", params: authorize_params
      code_from_redirect
    end

    it "exchanges a valid code + verifier for an access token, then resolves the user" do
      code = issued_code

      post "/oauth/access_token",
           params: { code: code, redirect_uri: redirect_uri, code_verifier: code_verifier, grant_type: "authorization_code" },
           headers: basic_auth_header(preview.app_name, PreviewSignon::CLIENT_SECRET)

      expect(response).to have_http_status(:ok)
      access_token = JSON.parse(response.body)["access_token"]
      expect(access_token).to be_present

      get "/user.json", params: { client_id: preview.app_name }, headers: { "HTTP_AUTHORIZATION" => "Bearer #{access_token}" }

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["user"]).to include(
        "uid" => "user-uid",
        "name" => "Jo Previewer",
        "email" => "jo@example.com",
        "permissions" => %w[signin],
      )
    end

    it "grants an app's own configured permissions (e.g. Whitehall's)" do
      whitehall_preview = create(:preview, app_name: "whitehall", branch: "my-branch", status: :running)
      login_as(user)
      get "/oauth/authorize", params: authorize_params(
        client_id: "whitehall",
        redirect_uri: "#{whitehall_preview.url}/auth/gds/callback",
      )
      code = code_from_redirect

      post "/oauth/access_token",
           params: { code: code, redirect_uri: "#{whitehall_preview.url}/auth/gds/callback", code_verifier: code_verifier },
           headers: basic_auth_header("whitehall", PreviewSignon::CLIENT_SECRET)
      access_token = JSON.parse(response.body)["access_token"]

      get "/user.json", params: { client_id: "whitehall" }, headers: { "HTTP_AUTHORIZATION" => "Bearer #{access_token}" }

      expect(JSON.parse(response.body)["user"]["permissions"]).to include("GDS Admin", "Sidekiq Admin")
    end

    it "rejects the wrong client_secret" do
      code = issued_code

      post "/oauth/access_token",
           params: { code: code, redirect_uri: redirect_uri, code_verifier: code_verifier },
           headers: basic_auth_header(preview.app_name, "wrong-secret")

      expect(response).to have_http_status(:unauthorized)
    end

    it "rejects the wrong code_verifier" do
      code = issued_code

      post "/oauth/access_token",
           params: { code: code, redirect_uri: redirect_uri, code_verifier: "wrong-verifier" * 4 },
           headers: basic_auth_header(preview.app_name, PreviewSignon::CLIENT_SECRET)

      expect(response).to have_http_status(:bad_request)
      expect(JSON.parse(response.body)["error"]).to eq("invalid_grant")
    end

    it "rejects reusing the same code twice" do
      code = issued_code
      post "/oauth/access_token",
           params: { code: code, redirect_uri: redirect_uri, code_verifier: code_verifier },
           headers: basic_auth_header(preview.app_name, PreviewSignon::CLIENT_SECRET)
      expect(response).to have_http_status(:ok)

      post "/oauth/access_token",
           params: { code: code, redirect_uri: redirect_uri, code_verifier: code_verifier },
           headers: basic_auth_header(preview.app_name, PreviewSignon::CLIENT_SECRET)

      expect(response).to have_http_status(:bad_request)
    end

    it "rejects an unknown bearer token" do
      get "/user.json", params: { client_id: preview.app_name }, headers: { "HTTP_AUTHORIZATION" => "Bearer not-a-real-token" }

      expect(response).to have_http_status(:unauthorized)
    end
  end
end

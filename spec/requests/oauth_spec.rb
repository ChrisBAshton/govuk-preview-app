require "rails_helper"

RSpec.describe "GET /oauth/continue" do
  let(:user) { create(:user, uid: "user-uid", name: "Jo Previewer", email: "jo@example.com") }
  let(:preview) { create(:preview, app_name: "frontend", branch: "my-branch", status: :running) }

  def redirect_params
    URI.decode_www_form(URI.parse(response.headers["Location"]).query).to_h
  end

  it "bounces back to redirect_uri with a signed preview_auth token, once signed in" do
    login_as(user)

    get "/oauth/continue", params: { redirect_uri: "#{preview.url}/some/page" }

    expect(response).to have_http_status(:redirect)
    uri = URI.parse(response.headers["Location"])
    expect("#{uri.scheme}://#{uri.host}#{uri.path}").to eq("#{preview.url}/some/page")
    expect(PreviewSignon.uid_for_preview_access_token(redirect_params["preview_auth"])).to eq(user.uid)
  end

  it "rejects a redirect_uri that isn't a real, running preview's own URL" do
    login_as(user)

    get "/oauth/continue", params: { redirect_uri: "https://evil.example.com/some/page" }

    expect(response).to have_http_status(:bad_request)
  end

  it "accepts any path under a real preview, not just a fixed callback path" do
    login_as(user)

    get "/oauth/continue", params: { redirect_uri: "#{preview.url}/" }

    uri = URI.parse(response.headers["Location"])
    expect("#{uri.scheme}://#{uri.host}#{uri.path}").to eq("#{preview.url}/")
  end
end

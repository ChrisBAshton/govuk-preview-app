require "rails_helper"

RSpec.describe PreviewEnv do
  describe ".for" do
    it "points PLEK_SERVICE_SIGNON_URI at Preview App's own hostname, not wherever previews themselves live" do
      ENV["PREVIEW_APP_BASE_DOMAIN"] = "govuk-preview-app.example.com"
      ENV["PREVIEW_HOSTNAME_BASE_DOMAIN"] = "govuk-preview-app.eks.example.com"
      preview = create(:preview, app_name: "frontend", branch: "my-branch")

      env = described_class.for(preview)

      expect(env["PLEK_SERVICE_SIGNON_URI"]).to eq("#{Preview.scheme}://govuk-preview-app.example.com")
    ensure
      ENV.delete("PREVIEW_APP_BASE_DOMAIN")
      ENV.delete("PREVIEW_HOSTNAME_BASE_DOMAIN")
    end

    it "forces gds-sso's real strategy, with the previewed app's own name as the OAuth client id" do
      preview = create(:preview, app_name: "frontend", branch: "my-branch")

      env = described_class.for(preview)

      expect(env["GDS_SSO_STRATEGY"]).to eq("real")
      expect(env["GDS_SSO_OAUTH_ID"]).to eq("frontend")
      expect(env["GDS_SSO_OAUTH_SECRET"]).to eq(PreviewSignon::CLIENT_SECRET)
    end
  end
end

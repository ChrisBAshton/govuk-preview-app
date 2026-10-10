require "rails_helper"

RSpec.describe PreviewEnv do
  describe ".for" do
    it "forces gds-sso's mock strategy, carrying no OAuth2 client config a previewed app's pod would ever call out with" do
      preview = create(:preview, app_name: "frontend", branch: "my-branch")

      env = described_class.for(preview)

      expect(env["GDS_SSO_STRATEGY"]).to eq("mock")
      expect(env).not_to include("GDS_SSO_OAUTH_ID", "GDS_SSO_OAUTH_SECRET", "PLEK_SERVICE_SIGNON_URI")
    end

    it "points PREVIEW_APP_INTERNAL_URL at its own pod's Service - the same address every other app reaches it at" do
      preview = create(:preview, app_name: "frontend", branch: "my-branch")

      env = described_class.for(preview)

      expect(env["PREVIEW_APP_INTERNAL_URL"]).to eq("http://#{KubernetesRunner.new(preview).container_name}")
    end
  end
end

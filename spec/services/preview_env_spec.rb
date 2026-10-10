require "rails_helper"

RSpec.describe PreviewEnv do
  describe ".for" do
    it "forces gds-sso's mock strategy, carrying no OAuth2 client config a previewed app's pod would ever call out with" do
      preview = create(:preview, app_name: "frontend", branch: "my-branch")

      env = described_class.for(preview)

      expect(env["GDS_SSO_STRATEGY"]).to eq("mock")
      expect(env).not_to include("GDS_SSO_OAUTH_ID", "GDS_SSO_OAUTH_SECRET", "PLEK_SERVICE_SIGNON_URI")
    end
  end
end

require "rails_helper"

RSpec.describe GovukApps do
  describe ".all" do
    it "loads app definitions from config/govuk_apps.yml" do
      expect(described_class.all).not_to be_empty
      expect(described_class.all).to all(be_a(described_class::Definition))
    end
  end

  describe ".app_names" do
    it "includes frontend" do
      expect(described_class.app_names).to include("frontend")
    end
  end

  describe ".find" do
    it "returns the definition for a known app" do
      definition = described_class.find("frontend")

      expect(definition.repo_url).to eq("https://github.com/alphagov/frontend.git")
      expect(definition.port_env_var).to eq("PORT")
      expect(definition.env).to eq("PLEK_SERVICE_CONTENT_STORE_URI" => "https://www.gov.uk/api")
    end

    it "returns nil for an unknown app" do
      expect(described_class.find("not-a-real-app")).to be_nil
    end
  end
end

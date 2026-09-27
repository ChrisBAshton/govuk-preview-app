require "rails_helper"

RSpec.describe GovukApps do
  describe ".all" do
    it "loads app definitions from config/govuk_apps.yml" do
      expect(described_class.all).not_to be_empty
      expect(described_class.all).to all(be_a(described_class::Definition))
    end
  end

  describe ".app_names" do
    it "includes frontend, publishing-api and whitehall" do
      expect(described_class.app_names).to include("frontend", "publishing-api", "whitehall")
    end
  end

  describe ".find" do
    it "returns the definition for a known app, with no database/dependencies by default" do
      definition = described_class.find("frontend")

      expect(definition.repo_url).to eq("https://github.com/alphagov/frontend.git")
      expect(definition.port_env_var).to eq("PORT")
      expect(definition.env).to eq("PLEK_SERVICE_CONTENT_STORE_URI" => "https://www.gov.uk/api")
      expect(definition.dependencies).to eq([])
      expect(definition.database).to be_nil
    end

    it "parses a declared database" do
      definition = described_class.find("publishing-api")

      expect(definition.database).to have_attributes(adapter: "postgresql", image: "postgres:17")
    end

    it "parses declared dependencies" do
      definition = described_class.find("whitehall")

      expect(definition.dependencies).to eq(%w[publishing-api])
      expect(definition.database).to have_attributes(adapter: "mysql2", image: "mysql:8")
    end

    it "returns nil for an unknown app" do
      expect(described_class.find("not-a-real-app")).to be_nil
    end
  end
end

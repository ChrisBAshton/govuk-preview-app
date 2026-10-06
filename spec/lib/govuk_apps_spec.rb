require "rails_helper"

RSpec.describe GovukApps do
  describe ".all" do
    it "loads app definitions from config/govuk_apps.yml" do
      expect(described_class.all).not_to be_empty
      expect(described_class.all).to all(be_a(described_class::Definition))
    end
  end

  describe ".app_names" do
    it "includes frontend, publishing-api, whitehall, and their draft-stack counterparts" do
      expect(described_class.app_names).to include(
        "frontend", "draft-frontend", "content-store", "draft-content-store", "publishing-api", "whitehall",
        "govuk-publishing-components", "govuk-content-publishing-guidance",
        "collections"
      )
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
      expect(definition.setup_tasks).to eq([])
      expect(definition.worker_command).to be_nil
      expect(definition.env_aliases).to eq({})
    end

    it "returns false for publicly_readable when the manifest doesn't declare it" do
      expect(described_class.find("whitehall").publicly_readable).to be(false)
    end

    it "parses a declared database" do
      definition = described_class.find("publishing-api")

      expect(definition.database).to have_attributes(adapter: "postgresql", image: "postgres:17")
    end

    it "parses declared dependencies, in order" do
      definition = described_class.find("whitehall")

      expect(definition.dependencies).to eq(%w[publishing-api frontend draft-frontend])
      expect(definition.database).to have_attributes(adapter: "mysql2", image: "mysql:8")
    end

    it "parses declared setup_tasks" do
      definition = described_class.find("whitehall")

      expect(definition.setup_tasks).to eq(%w[taxonomy:populate_end_to_end_test_data taxonomy:rebuild_cache])
    end

    it "parses a declared worker_command and dependency" do
      definition = described_class.find("publishing-api")

      expect(definition.worker_command).to eq(%w[bundle exec sidekiq -C ./config/sidekiq.yml])
      expect(definition.dependencies).to eq(%w[content-store draft-content-store])
    end

    it "parses publicly_readable" do
      expect(described_class.find("content-store").publicly_readable).to be(true)
      expect(described_class.find("draft-content-store").publicly_readable).to be(true)
      expect(described_class.find("frontend").publicly_readable).to be(true)
      expect(described_class.find("draft-frontend").publicly_readable).to be(true)
      expect(described_class.find("publishing-api").publicly_readable).to be(false)
    end

    it "parses declared env_aliases" do
      expect(described_class.find("draft-frontend").env_aliases).to eq(
        "PLEK_SERVICE_CONTENT_STORE_URI" => "PLEK_SERVICE_DRAFT_CONTENT_STORE_URI",
      )
    end

    it "parses govuk-publishing-components, including its Procfile-only MAIN_COMPONENT_GUIDE flag" do
      definition = described_class.find("govuk-publishing-components")

      expect(definition.repo_url).to eq("https://github.com/alphagov/govuk_publishing_components.git")
      expect(definition.port_env_var).to eq("PORT")
      expect(definition.env).to eq(
        "GOVUK_WEBSITE_ROOT" => "https://www.gov.uk",
        "PLEK_SERVICE_CONTENT_STORE_URI" => "https://www.gov.uk/api",
        "PLEK_SERVICE_RUMMAGER_URI" => "https://www.gov.uk/api",
        "MAIN_COMPONENT_GUIDE" => "true",
        "RAILS_ENV" => "development",
        "RACK_ENV" => "development",
      )
    end

    it "parses govuk-content-publishing-guidance, a plain app with no extra env" do
      definition = described_class.find("govuk-content-publishing-guidance")

      expect(definition.repo_url).to eq("https://github.com/alphagov/govuk-content-publishing-guidance.git")
      expect(definition.port_env_var).to eq("PORT")
      expect(definition.env).to eq({})
    end

    it "parses collections" do
      definition = described_class.find("collections")

      expect(definition.repo_url).to eq("https://github.com/alphagov/collections.git")
      expect(definition.env).to eq(
        "GOVUK_APP_DOMAIN" => "www.gov.uk",
        "GOVUK_WEBSITE_ROOT" => "https://www.gov.uk",
        "PLEK_SERVICE_CONTENT_STORE_URI" => "https://www.gov.uk/api",
        "PLEK_SERVICE_SEARCH_API_URI" => "https://www.gov.uk/api",
      )
    end

    it "returns nil for an unknown app" do
      expect(described_class.find("not-a-real-app")).to be_nil
    end

    it "raises if the manifest ever declares a repo_url outside the alphagov org" do
      described_class.instance_variable_set(:@all, nil)
      allow(YAML).to receive(:load_file).and_return(
        "evil-app" => { "repo_url" => "https://github.com/not-alphagov/evil.git", "port_env_var" => "PORT" },
      )

      expect { described_class.all }.to raise_error(/untrusted repo_url/)

      described_class.instance_variable_set(:@all, nil)
    end
  end

  describe ".trusted_repo_url?" do
    it "is true for a real alphagov GitHub repo" do
      expect(described_class.trusted_repo_url?("https://github.com/alphagov/whitehall.git")).to be(true)
    end

    it "is false for a different org" do
      expect(described_class.trusted_repo_url?("https://github.com/not-alphagov/whitehall.git")).to be(false)
    end

    it "is false for a lookalike host" do
      expect(described_class.trusted_repo_url?("https://github.com.evil.com/alphagov/whitehall.git")).to be(false)
    end

    it "is false for a userinfo trick pointing at a different real host" do
      expect(described_class.trusted_repo_url?("https://github.com@evil.com/alphagov/whitehall.git")).to be(false)
    end

    it "is false for plain http" do
      expect(described_class.trusted_repo_url?("http://github.com/alphagov/whitehall.git")).to be(false)
    end

    it "is false for a malformed URL" do
      expect(described_class.trusted_repo_url?("not a url")).to be(false)
    end
  end

  describe ".dependency_tree" do
    it "lists every transitive dependency, in build order" do
      expect(described_class.dependency_tree("whitehall")).to eq(
        %w[publishing-api content-store draft-content-store frontend draft-frontend],
      )
    end
  end
end

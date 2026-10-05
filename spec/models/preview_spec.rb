require "rails_helper"

RSpec.describe Preview do
  it "has a valid factory" do
    expect(build(:preview)).to be_valid
  end

  describe "validations" do
    it "requires an app_name that's in the GOV.UK apps manifest" do
      preview = build(:preview, app_name: "not-a-real-app")

      expect(preview).not_to be_valid
      expect(preview.errors[:app_name]).to be_present
    end

    it "requires a branch" do
      preview = build(:preview, branch: nil)

      expect(preview).not_to be_valid
      expect(preview.errors[:branch]).to be_present
    end

    it "requires a unique slug" do
      create(:preview, app_name: "frontend", branch: "my-branch")
      preview = build(:preview, app_name: "frontend", branch: "my-branch")

      expect(preview).not_to be_valid
      expect(preview.errors[:slug]).to be_present
    end
  end

  describe "#generate_slug" do
    it "parameterizes the app name and branch into a slug" do
      preview = build(:preview, app_name: "frontend", branch: "My Feature/Branch")

      preview.valid?

      expect(preview.slug).to eq("frontend-my-feature-branch")
    end

    it "does not overwrite an explicitly set slug" do
      preview = build(:preview, app_name: "frontend", branch: "my-branch", slug: "custom-slug")

      preview.valid?

      expect(preview.slug).to eq("custom-slug")
    end

    it "scopes a dependency's slug to its parent, so two parents can each depend on the same app+branch" do
      parent_a = create(:preview, app_name: "whitehall", branch: "branch-a")
      parent_b = create(:preview, app_name: "whitehall", branch: "branch-b")

      dependent_a = create(:preview, app_name: "publishing-api", branch: "main", parent: parent_a)
      dependent_b = build(:preview, app_name: "publishing-api", branch: "main", parent: parent_b)

      expect(dependent_a.slug).to eq("publishing-api-main-for-#{parent_a.slug}")
      expect(dependent_b).to be_valid
      expect(dependent_b.slug).to eq("publishing-api-main-for-#{parent_b.slug}")
    end
  end

  describe "#parent / #dependents" do
    it "links a dependency preview to its parent" do
      parent = create(:preview, app_name: "whitehall", branch: "my-branch")
      dependent = create(:preview, app_name: "publishing-api", branch: "main", parent: parent)

      expect(dependent.parent).to eq(parent)
      expect(parent.dependents).to eq([dependent])
    end

    it "has no parent by default" do
      expect(create(:preview).parent).to be_nil
    end
  end

  describe ".base_domain" do
    it "defaults to the govuk-preview-app.dev.gov.uk domain" do
      expect(described_class.base_domain).to eq("govuk-preview-app.dev.gov.uk")
    end
  end

  describe ".scheme" do
    it "defaults to http" do
      expect(described_class.scheme).to eq("http")
    end
  end

  describe "#hostname" do
    it "combines the slug with the configured base domain" do
      preview = create(:preview, app_name: "frontend", branch: "my-branch")

      expect(preview.hostname).to eq("frontend-my-branch.govuk-preview-app.dev.gov.uk")
    end

    it "uses the randomised public_hostname instead of the slug for a publicly_readable app" do
      preview = create(:preview, app_name: "content-store", branch: "main")

      expect(preview.hostname).to eq("#{preview.public_hostname}.govuk-preview-app.dev.gov.uk")
      expect(preview.hostname).not_to include(preview.slug)
    end
  end

  describe "#generate_public_hostname" do
    it "sets a random hostname, prefixed by the app name, for a publicly_readable app" do
      preview = create(:preview, app_name: "content-store", branch: "main")

      expect(preview.public_hostname).to match(/\Acontent-store-[a-z0-9]{7}\z/)
    end

    it "sets a different public_hostname for each instance of the same app" do
      first = create(:preview, app_name: "content-store", branch: "main")
      second = create(:preview, app_name: "content-store", branch: "main", parent: create(:preview, app_name: "publishing-api", branch: "main"))

      expect(first.public_hostname).not_to eq(second.public_hostname)
    end

    it "leaves public_hostname blank for an app that isn't publicly_readable" do
      preview = create(:preview, app_name: "publishing-api", branch: "main")

      expect(preview.public_hostname).to be_nil
    end
  end

  describe "#publicly_readable?" do
    it "is true for an app the manifest marks publicly_readable (content-store)" do
      expect(create(:preview, app_name: "content-store", branch: "main").publicly_readable?).to be(true)
    end

    it "is false for an app the manifest doesn't mark publicly_readable (publishing-api)" do
      expect(create(:preview, app_name: "publishing-api", branch: "main").publicly_readable?).to be(false)
    end
  end

  describe "#url" do
    it "combines the configured scheme with the hostname" do
      preview = create(:preview, app_name: "frontend", branch: "my-branch")

      expect(preview.url).to eq("http://frontend-my-branch.govuk-preview-app.dev.gov.uk")
    end

    it "appends the external port when PREVIEW_APP_NGINX_PORT is set" do
      preview = create(:preview, app_name: "frontend", branch: "my-branch")
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("PREVIEW_APP_NGINX_PORT").and_return("8080")

      expect(preview.url).to eq("http://frontend-my-branch.govuk-preview-app.dev.gov.uk:8080")
    end
  end

  describe "status" do
    it "defaults to queued" do
      expect(described_class.new.status).to eq("queued")
    end
  end
end

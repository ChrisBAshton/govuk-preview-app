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
  end

  describe ".base_domain" do
    it "defaults to the govuk-app-preview.dev.gov.uk domain" do
      expect(described_class.base_domain).to eq("govuk-app-preview.dev.gov.uk")
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

      expect(preview.hostname).to eq("frontend-my-branch.govuk-app-preview.dev.gov.uk")
    end
  end

  describe "#url" do
    it "combines the configured scheme with the hostname" do
      preview = create(:preview, app_name: "frontend", branch: "my-branch")

      expect(preview.url).to eq("http://frontend-my-branch.govuk-app-preview.dev.gov.uk")
    end
  end

  describe "status" do
    it "defaults to queued" do
      expect(described_class.new.status).to eq("queued")
    end
  end
end

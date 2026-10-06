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

    it "truncates and appends a digest when the naive slug would exceed the 63-character DNS label limit" do
      enable_local_images
      preview = build(:preview, app_name: "govuk-publishing-components", branch: "local:main-807400d-dirty-20261006103043")

      preview.valid?

      expect(preview.slug.length).to eq(63)
      expect(preview.slug).to start_with("govuk-publishing-components-local-main-807400d-dirty-2")
    end

    it "produces distinct truncated slugs for branches that only differ after the truncation point" do
      enable_local_images
      long_branch = "local:#{'a' * 60}"
      preview_one = build(:preview, app_name: "frontend", branch: "#{long_branch}-one")
      preview_two = build(:preview, app_name: "frontend", branch: "#{long_branch}-two")

      preview_one.valid?
      preview_two.valid?

      expect(preview_one.slug).not_to eq(preview_two.slug)
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

    it "uses the randomised public_hostname instead of the slug for a publicly_readable dependency" do
      parent = create(:preview, app_name: "publishing-api", branch: "my-branch")
      dependent = create(:preview, app_name: "content-store", branch: "main", parent: parent)

      expect(dependent.hostname).to eq("#{dependent.public_hostname}.govuk-preview-app.dev.gov.uk")
      expect(dependent.hostname).not_to include(dependent.slug)
    end
  end

  describe "#generate_public_hostname" do
    it "sets a random hostname, prefixed by the app name, for a publicly_readable dependency" do
      parent = create(:preview, app_name: "publishing-api", branch: "my-branch")
      dependent = create(:preview, app_name: "content-store", branch: "main", parent: parent)

      expect(dependent.public_hostname).to match(/\Acontent-store-[a-z0-9]{7}\z/)
    end

    it "sets a different public_hostname for each instance of the same app" do
      first = create(:preview, app_name: "content-store", branch: "main", parent: create(:preview, app_name: "publishing-api", branch: "branch-a"))
      second = create(:preview, app_name: "content-store", branch: "main", parent: create(:preview, app_name: "publishing-api", branch: "branch-b"))

      expect(first.public_hostname).not_to eq(second.public_hostname)
    end

    it "leaves public_hostname blank for a dependency that isn't publicly_readable" do
      parent = create(:preview, app_name: "whitehall", branch: "my-branch")
      dependent = create(:preview, app_name: "publishing-api", branch: "main", parent: parent)

      expect(dependent.public_hostname).to be_nil
    end

    it "leaves public_hostname blank for a standalone, top-level preview, even if its app is publicly_readable" do
      preview = create(:preview, app_name: "content-store", branch: "main")

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

  describe "#full_stack" do
    it "is ignored for an app whose full stack is no different from its core one" do
      expect(create(:preview, app_name: "frontend", full_stack: true).full_stack).to be(false)
      expect(create(:preview, app_name: "whitehall", full_stack: true).full_stack).to be(true)
    end
  end

  describe "#url" do
    it "combines the configured scheme with the hostname" do
      preview = create(:preview, app_name: "frontend", branch: "my-branch")

      expect(preview.url).to eq("http://frontend-my-branch.govuk-preview-app.dev.gov.uk")
    end

    it "appends the external port when PREVIEW_APP_EXTERNAL_PORT is set" do
      preview = create(:preview, app_name: "frontend", branch: "my-branch")
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("PREVIEW_APP_EXTERNAL_PORT").and_return("8080")

      expect(preview.url).to eq("http://frontend-my-branch.govuk-preview-app.dev.gov.uk:8080")
    end
  end

  describe "status" do
    it "defaults to queued" do
      expect(described_class.new.status).to eq("queued")
    end
  end

  describe "local image branches" do
    it "rejects a local: branch unless local images are enabled" do
      preview = build(:preview, app_name: "frontend", branch: "local:my-branch-abc1234")

      expect(preview).not_to be_valid
      expect(preview.errors[:branch]).to include("can only use a local image in local development")
    end

    it "accepts a local: branch when local images are enabled" do
      enable_local_images

      expect(build(:preview, app_name: "frontend", branch: "local:my-branch-abc1234")).to be_valid
    end

    it "rejects a local: tag that isn't a plain Docker tag" do
      enable_local_images
      preview = build(:preview, app_name: "frontend", branch: "local:evil.example/image:latest")

      expect(preview).not_to be_valid
      expect(preview.errors[:branch]).to include("has an invalid local image tag")
    end
  end
end

require "rails_helper"

RSpec.describe ImageResolver do
  let(:app) { GovukApps.find("whitehall") }
  let(:manifest_url) { %r{\Ahttps://ghcr\.io/v2/alphagov/govuk/whitehall/manifests/} }

  def resolver_for(branch)
    described_class.new(app, branch).tap { |resolver| allow(resolver).to receive(:pause) }
  end

  before do
    stub_request(:get, "https://ghcr.io/token?scope=repository:alphagov/govuk/whitehall:pull")
      .to_return(json_response({ token: "anon" }))
  end

  it "derives the image name from the manifest's repo_url" do
    expect(resolver_for("main").image_name).to eq("whitehall")
  end

  it "resolves main to the latest release tag's image" do
    stub_request(:get, "https://api.github.com/repos/alphagov/whitehall/releases/latest")
      .to_return(json_response({ tag_name: "v3355" }))
    stub_request(:head, "https://ghcr.io/v2/alphagov/govuk/whitehall/manifests/v3355").to_return(status: 200)

    expect(resolver_for("main").resolve!).to eq("ghcr.io/alphagov/govuk/whitehall:v3355")
  end

  it "resolves a branch to a tag matching its name, waiting until it's been pushed" do
    manifest = stub_request(:head, "https://ghcr.io/v2/alphagov/govuk/whitehall/manifests/my-branch")
      .to_return({ status: 404 }, { status: 200 })

    expect(resolver_for("my-branch").resolve!).to eq("ghcr.io/alphagov/govuk/whitehall:my-branch")
    expect(manifest).to have_been_requested.twice
    expect(WebMock).not_to have_requested(:get, /github\.com/)
  end

  it "points the image at PREVIEW_APP_IMAGE_REGISTRY when set (e.g. the ECR pull-through cache)" do
    stub_request(:get, "https://api.github.com/repos/alphagov/whitehall/releases/latest").to_return(json_response({ tag_name: "v1" }))
    stub_request(:head, manifest_url).to_return(status: 200)
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("PREVIEW_APP_IMAGE_REGISTRY", anything).and_return("123.dkr.ecr.eu-west-1.amazonaws.com/github/alphagov/govuk")

    expect(resolver_for("main").resolve!).to eq("123.dkr.ecr.eu-west-1.amazonaws.com/github/alphagov/govuk/whitehall:v1")
  end

  it "raises a helpful error when the image never appears" do
    stub_request(:head, manifest_url).to_return(status: 404)
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("PREVIEW_APP_IMAGE_WAIT_SECONDS", 1800).and_return("-1")

    expect { resolver_for("my-branch").resolve! }
      .to raise_error(described_class::ImageError, /whitehall:my-branch was published.*Build image from PR/)
  end

  describe "local: sources" do
    it "resolves to the locally-loaded image, without asking GitHub or GHCR" do
      enable_local_images

      expect(resolver_for("local:my-branch-abc1234").resolve!).to eq("govuk-preview-local/whitehall:my-branch-abc1234")
      expect(WebMock).not_to have_requested(:any, /github|ghcr/)
    end

    it "uses the repo's image for a manifest entry sharing it (draft-frontend -> frontend)" do
      enable_local_images

      expect(described_class.new(GovukApps.find("draft-frontend"), "local:x").resolve!).to eq("govuk-preview-local/frontend:x")
    end

    it "refuses local images unless enabled" do
      expect { resolver_for("local:my-branch").resolve! }.to raise_error(described_class::ImageError, /only available in local development/)
    end

    it "refuses a tag that could smuggle in another image" do
      enable_local_images

      expect { resolver_for("local:ghcr.io/evil/image").resolve! }.to raise_error(described_class::ImageError, /isn't a valid image tag/)
    end
  end
end

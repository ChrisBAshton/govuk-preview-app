require "rails_helper"

RSpec.describe StackRedis do
  let(:whitehall) { create(:preview, app_name: "whitehall", branch: "my-branch") }

  describe ".url_for" do
    it "gives every app in a stack the stack's own Redis, each with its own database" do
      publishing_api = create(:preview, app_name: "publishing-api", branch: "main", parent: whitehall)
      content_store = create(:preview, app_name: "content-store", branch: "main", parent: publishing_api)
      redis = "redis://govuk-preview-app-whitehall-my-branch-redis:6379"

      expect(described_class.url_for(whitehall)).to eq("#{redis}/0")
      expect(described_class.url_for(publishing_api)).to eq("#{redis}/1")
      expect(described_class.url_for(content_store)).to eq("#{redis}/2")
    end

    it "never gives two stacks the same Redis" do
      other = create(:preview, app_name: "whitehall", branch: "other-branch")

      expect(described_class.url_for(whitehall)).not_to eq(described_class.url_for(other))
    end
  end

  describe "#start!" do
    it "applies a restricted-compliant Redis with no persistence, labelled as part of the stack" do
      api = kubernetes_api
      redis = described_class.new(whitehall, api:)
      applied = {}
      stub_request(:patch, /k8s\.test/).to_return do |req|
        applied[req.uri.path.split("/")[-2]] = JSON.parse(req.body)
        json_response({})
      end

      redis.start!

      container = applied["deployments"].dig("spec", "template", "spec", "containers", 0)
      expect(container["args"]).to include("--save", "", "--appendonly", "no")
      expect(container["securityContext"]).to include("runAsNonRoot" => true, "allowPrivilegeEscalation" => false)
      expect(applied["deployments"].dig("metadata", "labels")).to include("govuk-preview-app/root-id" => whitehall.id.to_s)
      expect(applied["services"].dig("spec", "ports", 0, "port")).to eq(6379)
    end
  end
end

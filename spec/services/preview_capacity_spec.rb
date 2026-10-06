require "rails_helper"

RSpec.describe PreviewCapacity do
  let(:api) { kubernetes_api }
  let(:quota_path) { api.path("v1", "resourcequotas", "previews") }
  let(:root) { create(:preview, app_name: "frontend", branch: "new-branch") }

  # frontend: one app pod - 384Mi requested, 1536Mi limit (+ one task pod
  # while building).
  def stub_quota(requests_used:, requests_hard: "1Gi", limits_used: "0", limits_hard: "64Gi")
    stub_request(:get, k8s_url(quota_path)).to_return(json_response({
      status: {
        hard: { "requests.memory" => requests_hard, "limits.memory" => limits_hard },
        used: { "requests.memory" => requests_used, "limits.memory" => limits_used },
      },
    }))
  end

  def stub_pods(items = [])
    stub_request(:get, k8s_url(api.path("v1", "pods"))).with(query: hash_including({})).to_return(json_response({ items: items }))
  end

  def capacity(building: false)
    described_class.new(root, building:, api:)
  end

  before { stub_pods }

  describe "#shortfall" do
    it "is empty when the whole stack fits in what's free" do
      stub_quota(requests_used: "600Mi")

      expect(capacity.shortfall).to eq({})
    end

    it "counts a task pod's worth of extra room while building" do
      stub_quota(requests_used: "600Mi")

      expect(capacity(building: true).shortfall).to eq("requests.memory" => 344)
    end

    it "checks limits as well as requests" do
      stub_quota(requests_used: "0", limits_used: "63Gi")

      expect(capacity.shortfall).to eq("limits.memory" => 512)
    end

    it "doesn't count what the stack's own pods already hold (e.g. resuming an interrupted build)" do
      stub_quota(requests_used: "900Mi")
      stub_pods([{ status: { phase: "Running" }, spec: { containers: [{ resources: { requests: { memory: "384Mi" }, limits: { memory: "1536Mi" } } }] } }])

      expect(capacity.shortfall).to eq({})
    end

    it "manages nothing when there's no quota" do
      stub_request(:get, k8s_url(quota_path)).to_return(status: 404)

      expect(capacity.shortfall).to eq({})
    end
  end

  describe "stack size" do
    it "counts only a core stack's apps unless the full stack was asked for" do
      stub_quota(requests_used: "0", requests_hard: "64Gi")
      core = described_class.new(create(:preview, app_name: "whitehall", branch: "core"), api:)
      full = described_class.new(create(:preview, app_name: "whitehall", branch: "full", full_stack: true), api:)

      # whitehall + MySQL, publishing-api web + worker + Postgres
      expect(core.send(:stack_needs)["requests.memory"]).to eq((384 * 3) + (256 * 2))
      # ...plus two Content Stores (each with Postgres) and two Frontends
      expect(full.send(:stack_needs)["requests.memory"]).to eq((384 * 7) + (256 * 4))
    end
  end

  describe "#make_room!" do
    let(:sleepers) { {} }

    before do
      allow(PreviewSleeper).to receive(:new) do |preview, **|
        sleepers[preview.id] ||= instance_double(PreviewSleeper, sleep!: nil, wait_until_asleep!: nil)
      end
    end

    it "does nothing when there's already room" do
      stub_quota(requests_used: "0")

      capacity.make_room!

      expect(PreviewSleeper).not_to have_received(:new)
    end

    it "sleeps the least recently used other previews until there's room" do
      oldest = create(:preview, app_name: "whitehall", branch: "a", status: :running, last_accessed_at: 2.hours.ago)
      never_visited = create(:preview, app_name: "frontend", branch: "b", status: :running, last_accessed_at: nil)
      newer = create(:preview, app_name: "frontend", branch: "c", status: :running, last_accessed_at: 1.hour.ago)
      stub_request(:get, k8s_url(quota_path)).to_return(
        json_response({ status: { hard: { "requests.memory" => "1Gi" }, used: { "requests.memory" => "1Gi" } } }),
        json_response({ status: { hard: { "requests.memory" => "1Gi" }, used: { "requests.memory" => "900Mi" } } }),
        json_response({ status: { hard: { "requests.memory" => "1Gi" }, used: { "requests.memory" => "200Mi" } } }),
      )

      capacity.make_room!

      expect(sleepers.keys).to eq([never_visited.id, oldest.id])
      expect(sleepers[oldest.id]).to have_received(:wait_until_asleep!)
      expect(sleepers).not_to have_key(newer.id)
    end

    it "never sleeps a preview used in the last 15 minutes, or one that isn't running, and says why it can't make room" do
      create(:preview, app_name: "frontend", branch: "recent", status: :running, last_accessed_at: 5.minutes.ago)
      create(:preview, app_name: "frontend", branch: "building", status: :starting)
      stub_quota(requests_used: "1Gi")

      expect { capacity.make_room! }.to raise_error(described_class::AtCapacityError, /needs 384Mi more memory than is free/)
      expect(PreviewSleeper).not_to have_received(:new)
    end
  end
end

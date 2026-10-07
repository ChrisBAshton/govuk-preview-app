require "rails_helper"

RSpec.describe PreviewSleeper do
  let(:api) { kubernetes_api }
  let(:root) { create(:preview, app_name: "publishing-api", branch: "my-branch", status: :running) }
  let!(:content_store) { create(:preview, app_name: "content-store", branch: "main", parent: root, status: :running) }
  let(:sleeper) { described_class.new(root, api:) }
  let(:scaled) { [] }

  before do
    allow(sleeper).to receive(:pause)
    stub_request(:patch, /k8s\.test/).to_return do |req|
      scaled << [req.uri.path.split("/").last, JSON.parse(req.body).dig("spec", "replicas")]
      json_response({})
    end
  end

  describe "#sleep!" do
    it "doesn't count as an interaction - it's often automatic, to make room for another preview" do
      root.update_column(:last_interacted_at, 2.hours.ago)

      sleeper.sleep!

      expect(root.reload.last_interacted_at).to be_within(1.second).of(2.hours.ago)
    end

    it "scales every Deployment and database in the stack to zero, and marks the whole stack sleeping" do
      sleeper.sleep!

      expect(scaled).to contain_exactly(
        [KubernetesRunner.new(root).container_name, 0],
        [KubernetesRunner.new(root).worker_container_name, 0],
        [KubernetesDatabaseRunner.new(root, GovukApps.find("publishing-api").database).container_name, 0],
        [KubernetesRunner.new(content_store).container_name, 0],
        [StackRedis.new(root).name, 0],
        [KubernetesDatabaseRunner.new(content_store, GovukApps.find("content-store").database).container_name, 0],
      )
      expect([root.reload.status, content_store.reload.status]).to eq(%w[sleeping sleeping])
    end
  end

  describe "#wake!" do
    before do
      allow(PreviewCapacity).to receive(:make_room_for!)
      stub_request(:get, %r{/statefulsets/}).to_return(json_response({ status: { readyReplicas: 1 } }))
      stub_request(:get, %r{/deployments/}).to_return(json_response(rolled_out_deployment))
      sleeper.sleep!
      scaled.clear
    end

    it "makes room, scales databases up before apps, waits for everything, and marks the stack running" do
      sleeper.wake!

      expect(PreviewCapacity).to have_received(:make_room_for!).with(root)
      expect(scaled.map(&:last).uniq).to eq([1])
      database_scales = scaled.index { |name, _| name.end_with?("-db") }
      app_scales = scaled.index { |name, _| name == KubernetesRunner.new(root).container_name }
      expect(database_scales).to be < app_scales
      expect([root.reload.status, content_store.reload.status]).to eq(%w[running running])
      # Waking is automatic once asked for - the asking (a visit, or the Wake
      # button) is what counts as an interaction.
      expect(root.last_interacted_at).to be_nil
    end

    it "goes back to sleep, saying why, when there isn't room" do
      allow(PreviewCapacity).to receive(:make_room_for!).and_raise(PreviewCapacity::AtCapacityError, "At capacity: blah")

      sleeper.wake!

      expect(root.reload).to have_attributes(status: "sleeping", status_message: "Couldn't wake up: At capacity: blah")
      expect(content_store.reload.status).to eq("sleeping")
    end
  end
end

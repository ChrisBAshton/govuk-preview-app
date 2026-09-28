require "rails_helper"

RSpec.describe PreviewReconciler do
  let(:success) { instance_double(Process::Status, success?: true) }
  let(:failure) { instance_double(Process::Status, success?: false) }

  before do
    allow(DockerRunner).to receive(:daemon_reachable?).and_return(true)
  end

  describe ".run!" do
    it "leaves a genuinely running preview (no database) alone" do
      preview = create(:preview, app_name: "frontend", branch: "my-branch", status: :running)
      allow(DockerRunner).to receive(:new).with(preview).and_return(instance_double(DockerRunner, exists?: true))

      described_class.run!

      expect(preview.reload.status).to eq("running")
    end

    it "leaves a genuinely running preview with a database alone" do
      preview = create(:preview, app_name: "publishing-api", branch: "my-branch", status: :running)
      allow(DockerRunner).to receive(:new).with(preview).and_return(instance_double(DockerRunner, exists?: true))
      allow(DatabaseRunner).to receive(:new).and_return(instance_double(DatabaseRunner, exists?: true))

      described_class.run!

      expect(preview.reload.status).to eq("running")
    end

    it "marks a preview failed when its app container is gone" do
      preview = create(:preview, app_name: "frontend", branch: "my-branch", status: :running)
      allow(DockerRunner).to receive(:new).with(preview).and_return(instance_double(DockerRunner, exists?: false))

      described_class.run!

      expect(preview.reload).to have_attributes(status: "failed", status_message: /app container/)
    end

    it "marks a preview failed when only its database container is gone" do
      preview = create(:preview, app_name: "publishing-api", branch: "my-branch", status: :running)
      allow(DockerRunner).to receive(:new).with(preview).and_return(instance_double(DockerRunner, exists?: true))
      allow(DatabaseRunner).to receive(:new).and_return(instance_double(DatabaseRunner, exists?: false))

      described_class.run!

      expect(preview.reload).to have_attributes(status: "failed", status_message: /database container/)
      expect(preview.status_message).not_to include("app container")
    end

    it "reconciles a dependent preview the same way as a top-level one" do
      parent = create(:preview, app_name: "whitehall", branch: "my-branch", status: :running)
      dependent = create(:preview, app_name: "publishing-api", branch: "main", parent: parent, status: :running)
      allow(DockerRunner).to receive(:new) do |p|
        instance_double(DockerRunner, exists?: p != dependent)
      end
      allow(DatabaseRunner).to receive(:new).and_return(instance_double(DatabaseRunner, exists?: true))

      described_class.run!

      expect(parent.reload.status).to eq("running")
      expect(dependent.reload).to have_attributes(status: "failed", status_message: /app container/)
    end

    it "does nothing at all when the Docker daemon is unreachable" do
      preview = create(:preview, app_name: "frontend", branch: "my-branch", status: :running)
      allow(DockerRunner).to receive(:daemon_reachable?).and_return(false)
      allow(DockerRunner).to receive(:new)

      described_class.run!

      expect(preview.reload.status).to eq("running")
      expect(DockerRunner).not_to have_received(:new)
    end
  end
end

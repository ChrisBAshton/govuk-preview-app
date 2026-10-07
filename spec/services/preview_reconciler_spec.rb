require "rails_helper"

RSpec.describe PreviewReconciler do
  before do
    allow(KubernetesRunner).to receive(:api_reachable?).and_return(true)
  end

  describe ".run!" do
    it "marks a preview of an app no longer in the manifest failed, without looking for its infrastructure" do
      preview = create(:preview, app_name: "frontend", branch: "my-branch", status: :running)
      preview.update_column(:app_name, "removed-app")
      allow(KubernetesRunner).to receive(:new)

      described_class.run!

      expect(preview.reload).to have_attributes(status: "failed", status_message: /removed-app is no longer a previewable app/)
      expect(KubernetesRunner).not_to have_received(:new)
    end

    it "leaves a genuinely running preview (no database) alone" do
      preview = create(:preview, app_name: "frontend", branch: "my-branch", status: :running)
      allow(KubernetesRunner).to receive(:new).with(preview).and_return(instance_double(KubernetesRunner, exists?: true))

      described_class.run!

      expect(preview.reload.status).to eq("running")
    end

    it "leaves a genuinely running preview with a database alone" do
      preview = create(:preview, app_name: "publishing-api", branch: "my-branch", status: :running)
      allow(KubernetesRunner).to receive(:new).with(preview).and_return(instance_double(KubernetesRunner, exists?: true))
      allow(KubernetesDatabaseRunner).to receive(:new).and_return(instance_double(KubernetesDatabaseRunner, exists?: true))

      described_class.run!

      expect(preview.reload.status).to eq("running")
    end

    it "marks a preview failed when its app deployment is gone" do
      preview = create(:preview, app_name: "frontend", branch: "my-branch", status: :running)
      allow(KubernetesRunner).to receive(:new).with(preview).and_return(instance_double(KubernetesRunner, exists?: false))

      described_class.run!

      expect(preview.reload).to have_attributes(status: "failed", status_message: /app deployment/)
    end

    it "marks a preview failed when only its database is gone" do
      preview = create(:preview, app_name: "publishing-api", branch: "my-branch", status: :running)
      allow(KubernetesRunner).to receive(:new).with(preview).and_return(instance_double(KubernetesRunner, exists?: true))
      allow(KubernetesDatabaseRunner).to receive(:new).and_return(instance_double(KubernetesDatabaseRunner, exists?: false))

      described_class.run!

      expect(preview.reload).to have_attributes(status: "failed", status_message: /database/)
      expect(preview.status_message).not_to include("app deployment")
    end

    it "reconciles a dependent preview the same way as a top-level one" do
      parent = create(:preview, app_name: "whitehall", branch: "my-branch", status: :running)
      dependent = create(:preview, app_name: "publishing-api", branch: "main", parent: parent, status: :running)
      allow(KubernetesRunner).to receive(:new) do |p|
        instance_double(KubernetesRunner, exists?: p != dependent)
      end
      allow(KubernetesDatabaseRunner).to receive(:new).and_return(instance_double(KubernetesDatabaseRunner, exists?: true))

      described_class.run!

      expect(parent.reload.status).to eq("running")
      expect(dependent.reload).to have_attributes(status: "failed", status_message: /app deployment/)
    end

    it "does nothing at all when the Kubernetes API is unreachable" do
      preview = create(:preview, app_name: "frontend", branch: "my-branch", status: :running)
      allow(KubernetesRunner).to receive(:api_reachable?).and_return(false)
      allow(KubernetesRunner).to receive(:new)

      described_class.run!

      expect(preview.reload.status).to eq("running")
      expect(KubernetesRunner).not_to have_received(:new)
    end
  end
end

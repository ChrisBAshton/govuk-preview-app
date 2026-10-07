require "rails_helper"

RSpec.describe PreviewDestroyer do
  let(:stack_redis) { instance_double(StackRedis, stop!: nil) }

  before { allow(StackRedis).to receive(:new).and_return(stack_redis) }

  describe "#destroy!" do
    it "deletes any database of an app no longer in the manifest, as it can't tell whether there was one" do
      preview = create(:preview, app_name: "frontend", branch: "my-branch")
      preview.update_column(:app_name, "removed-app")
      allow(KubernetesRunner).to receive(:new).with(preview).and_return(instance_double(KubernetesRunner, stop!: nil))
      db = instance_double(KubernetesDatabaseRunner, stop!: nil)
      allow(KubernetesDatabaseRunner).to receive(:new).with(preview, nil).and_return(db)

      described_class.new(preview).destroy!

      expect(db).to have_received(:stop!)
      expect(Preview.exists?(preview.id)).to be false
    end

    it "deletes the preview's Kubernetes objects and destroys the record" do
      preview = create(:preview, app_name: "frontend", branch: "my-branch")
      runner = instance_double(KubernetesRunner, stop!: nil)
      allow(KubernetesRunner).to receive(:new).with(preview).and_return(runner)

      described_class.new(preview).destroy!

      expect(runner).to have_received(:stop!)
      expect(Preview.exists?(preview.id)).to be false
    end

    it "also deletes the database if the app declares one" do
      preview = create(:preview, app_name: "publishing-api", branch: "my-branch")
      allow(KubernetesRunner).to receive(:new).with(preview).and_return(instance_double(KubernetesRunner, stop!: nil))
      db = instance_double(KubernetesDatabaseRunner, stop!: nil)
      allow(KubernetesDatabaseRunner).to receive(:new).with(preview, GovukApps.find("publishing-api").database).and_return(db)

      described_class.new(preview).destroy!

      expect(db).to have_received(:stop!)
    end

    it "recursively destroys dependents first, before the parent's own resources" do
      parent = create(:preview, app_name: "whitehall", branch: "my-branch")
      dependent = create(:preview, app_name: "publishing-api", branch: "main", parent: parent)

      dependent_runner = instance_double(KubernetesRunner, stop!: nil)
      dependent_db = instance_double(KubernetesDatabaseRunner, stop!: nil)
      parent_runner = instance_double(KubernetesRunner, stop!: nil)
      parent_db = instance_double(KubernetesDatabaseRunner, stop!: nil)

      allow(KubernetesRunner).to receive(:new).with(dependent).and_return(dependent_runner)
      allow(KubernetesDatabaseRunner).to receive(:new).with(dependent, GovukApps.find("publishing-api").database).and_return(dependent_db)

      allow(KubernetesRunner).to receive(:new).with(parent).and_return(parent_runner)
      allow(KubernetesDatabaseRunner).to receive(:new).with(parent, GovukApps.find("whitehall").database).and_return(parent_db)

      described_class.new(parent).destroy!

      expect(dependent_runner).to have_received(:stop!)
      expect(dependent_db).to have_received(:stop!)
      expect(parent_runner).to have_received(:stop!)
      expect(parent_db).to have_received(:stop!)
      expect(Preview.exists?(dependent.id)).to be false
      expect(Preview.exists?(parent.id)).to be false
    end
  end
end

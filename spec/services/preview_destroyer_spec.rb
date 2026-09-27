require "rails_helper"

RSpec.describe PreviewDestroyer do
  describe "#destroy!" do
    it "stops the container, removes the checkout, and destroys the preview" do
      preview = create(:preview, app_name: "frontend", branch: "my-branch")
      docker = instance_double(DockerRunner, stop!: nil)
      checkout = instance_double(Checkout, remove!: nil)
      allow(DockerRunner).to receive(:new).with(preview).and_return(docker)
      allow(Checkout).to receive(:new).with(preview).and_return(checkout)

      described_class.new(preview).destroy!

      expect(docker).to have_received(:stop!)
      expect(checkout).to have_received(:remove!)
      expect(Preview.exists?(preview.id)).to be false
    end

    it "also stops the database if the app declares one" do
      preview = create(:preview, app_name: "publishing-api", branch: "my-branch")
      allow(DockerRunner).to receive(:new).with(preview).and_return(instance_double(DockerRunner, stop!: nil))
      allow(Checkout).to receive(:new).with(preview).and_return(instance_double(Checkout, remove!: nil))
      db = instance_double(DatabaseRunner, stop!: nil)
      allow(DatabaseRunner).to receive(:new).with(preview, GovukApps.find("publishing-api").database).and_return(db)

      described_class.new(preview).destroy!

      expect(db).to have_received(:stop!)
    end

    it "recursively destroys dependents first, before the parent's own resources" do
      parent = create(:preview, app_name: "whitehall", branch: "my-branch")
      dependent = create(:preview, app_name: "publishing-api", branch: "main", parent: parent)

      dependent_docker = instance_double(DockerRunner, stop!: nil)
      dependent_db = instance_double(DatabaseRunner, stop!: nil)
      parent_docker = instance_double(DockerRunner, stop!: nil)
      parent_db = instance_double(DatabaseRunner, stop!: nil)

      allow(DockerRunner).to receive(:new).with(dependent).and_return(dependent_docker)
      allow(DatabaseRunner).to receive(:new).with(dependent, GovukApps.find("publishing-api").database).and_return(dependent_db)
      allow(Checkout).to receive(:new).with(dependent).and_return(instance_double(Checkout, remove!: nil))

      allow(DockerRunner).to receive(:new).with(parent).and_return(parent_docker)
      allow(DatabaseRunner).to receive(:new).with(parent, GovukApps.find("whitehall").database).and_return(parent_db)
      allow(Checkout).to receive(:new).with(parent).and_return(instance_double(Checkout, remove!: nil))

      described_class.new(parent).destroy!

      expect(dependent_docker).to have_received(:stop!)
      expect(dependent_db).to have_received(:stop!)
      expect(parent_docker).to have_received(:stop!)
      expect(parent_db).to have_received(:stop!)
      expect(Preview.exists?(dependent.id)).to be false
      expect(Preview.exists?(parent.id)).to be false
    end
  end
end

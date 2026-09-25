require "rails_helper"

RSpec.describe PreviewsDestroyJob do
  let(:preview) { create(:preview, app_name: "frontend", branch: "my-branch") }

  it "stops the container, removes the checkout, and destroys the preview" do
    docker = instance_double(DockerRunner, stop!: nil)
    checkout = instance_double(Checkout, remove!: nil)

    allow(DockerRunner).to receive(:new).with(preview).and_return(docker)
    allow(Checkout).to receive(:new).with(preview).and_return(checkout)

    described_class.new.perform(preview.id)

    expect(docker).to have_received(:stop!)
    expect(checkout).to have_received(:remove!)
    expect(Preview.exists?(preview.id)).to be false
  end
end

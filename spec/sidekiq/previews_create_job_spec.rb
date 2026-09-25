require "rails_helper"

RSpec.describe PreviewsCreateJob do
  let(:preview) { create(:preview, app_name: "frontend", branch: "my-branch") }

  it "checks out, builds, allocates a port, starts the container, and marks the preview running" do
    checkout_path = Pathname.new("/tmp/some-checkout")
    checkout = instance_double(Checkout, checkout!: checkout_path)
    docker = instance_double(DockerRunner, build!: nil, start!: "container-123")

    allow(Checkout).to receive(:new).with(preview).and_return(checkout)
    allow(DockerRunner).to receive(:new).with(preview).and_return(docker)
    allow(PortAllocator).to receive(:allocate).and_return(20_456)

    described_class.new.perform(preview.id)

    expect(docker).to have_received(:build!).with(checkout_path)
    expect(preview.reload).to have_attributes(
      status: "running",
      port: 20_456,
      container_id: "container-123",
    )
  end

  it "marks the preview failed with the error message when checkout fails" do
    allow(Checkout).to receive(:new).with(preview).and_return(
      instance_double(Checkout, checkout!: nil).tap do |checkout|
        allow(checkout).to receive(:checkout!).and_raise(Checkout::GitError, "fatal: repo not found")
      end,
    )

    described_class.new.perform(preview.id)

    expect(preview.reload).to have_attributes(status: "failed", status_message: "fatal: repo not found")
  end

  it "marks the preview failed when no port is available" do
    allow(Checkout).to receive(:new).with(preview).and_return(instance_double(Checkout, checkout!: Pathname.new("/tmp/x")))
    allow(DockerRunner).to receive(:new).with(preview).and_return(instance_double(DockerRunner, build!: nil))
    allow(PortAllocator).to receive(:allocate).and_raise(PortAllocator::NoPortsAvailableError, "no free ports")

    described_class.new.perform(preview.id)

    expect(preview.reload).to have_attributes(status: "failed", status_message: "no free ports")
  end
end

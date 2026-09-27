require "rails_helper"

RSpec.describe PreviewBuilder do
  let(:checkout_path) { Pathname.new("/tmp/some-checkout") }

  def stub_checkout(preview, path: checkout_path)
    checkout = instance_double(Checkout, checkout!: path)
    allow(Checkout).to receive(:new).with(preview).and_return(checkout)
    checkout
  end

  def stub_docker(preview, start_result: "container-123")
    docker = instance_double(
      DockerRunner, build!: nil, start!: start_result, migrate!: nil, seed!: nil,
                    container_name: "govuk-preview-app-#{preview.slug}"
    )
    allow(DockerRunner).to receive(:new).with(preview).and_return(docker)
    docker
  end

  describe "#build!" do
    it "does nothing if the preview is already running" do
      preview = create(:preview, app_name: "frontend", branch: "my-branch", status: :running)
      allow(Checkout).to receive(:new)

      described_class.new(preview).build!

      expect(Checkout).not_to have_received(:new)
    end

    context "with an app that has no dependencies or database (frontend)" do
      it "checks out, builds, allocates a port, starts the container, and marks the preview running" do
        preview = create(:preview, app_name: "frontend", branch: "my-branch")
        checkout = stub_checkout(preview)
        docker = stub_docker(preview)
        allow(PortAllocator).to receive(:allocate).and_return(20_456)
        allow(ConfigOverrides).to receive(:new).and_return(instance_double(ConfigOverrides, write!: nil))

        described_class.new(preview).build!

        expect(docker).to have_received(:build!).with(checkout_path)
        expect(docker).to have_received(:start!).with(extra_env: {}, publish_port: true)
        expect(checkout).to have_received(:checkout!)
        expect(preview.reload).to have_attributes(status: "running", port: 20_456, container_id: "container-123")
      end

      it "marks the preview failed with the error message when checkout fails" do
        preview = create(:preview, app_name: "frontend", branch: "my-branch")
        checkout = instance_double(Checkout)
        allow(checkout).to receive(:checkout!).and_raise(Checkout::GitError, "fatal: repo not found")
        allow(Checkout).to receive(:new).with(preview).and_return(checkout)

        described_class.new(preview).build!

        expect(preview.reload).to have_attributes(status: "failed", status_message: "fatal: repo not found")
      end

      it "marks the preview failed when no port is available" do
        preview = create(:preview, app_name: "frontend", branch: "my-branch")
        stub_checkout(preview)
        stub_docker(preview)
        allow(ConfigOverrides).to receive(:new).and_return(instance_double(ConfigOverrides, write!: nil))
        allow(PortAllocator).to receive(:allocate).and_raise(PortAllocator::NoPortsAvailableError, "no free ports")

        described_class.new(preview).build!

        expect(preview.reload).to have_attributes(status: "failed", status_message: "no free ports")
      end
    end

    context "with an app that has a database (publishing-api)" do
      it "starts a database, migrates with its URL, and passes DATABASE_URL to the running container" do
        preview = create(:preview, app_name: "publishing-api", branch: "my-branch")
        stub_checkout(preview)
        docker = stub_docker(preview)
        allow(ConfigOverrides).to receive(:new).and_return(instance_double(ConfigOverrides, write!: nil))
        allow(PortAllocator).to receive(:allocate).and_return(20_456)
        db = instance_double(DatabaseRunner, start!: "postgresql://db/app_preview")
        allow(DatabaseRunner).to receive(:new).and_return(db)

        described_class.new(preview).build!

        expect(DatabaseRunner).to have_received(:new).with(preview, GovukApps.find("publishing-api").database)
        expect(docker).to have_received(:migrate!).with(extra_env: { "DATABASE_URL" => "postgresql://db/app_preview" })
        expect(docker).to have_received(:start!).with(extra_env: { "DATABASE_URL" => "postgresql://db/app_preview" }, publish_port: true)
        expect(preview.reload.status).to eq("running")
      end

      it "marks the preview running with a warning message when seeding fails, rather than failed" do
        preview = create(:preview, app_name: "publishing-api", branch: "my-branch")
        stub_checkout(preview)
        docker = stub_docker(preview)
        allow(docker).to receive(:seed!).and_raise(DockerRunner::DockerError, "boom")
        allow(ConfigOverrides).to receive(:new).and_return(instance_double(ConfigOverrides, write!: nil))
        allow(PortAllocator).to receive(:allocate).and_return(20_456)
        allow(DatabaseRunner).to receive(:new).and_return(instance_double(DatabaseRunner, start!: "postgresql://db/app_preview"))

        described_class.new(preview).build!

        expect(docker).to have_received(:start!)
        expect(preview.reload).to have_attributes(status: "running", status_message: "Seed data failed: boom")
      end
    end

    context "with an app that has a dependency (whitehall -> publishing-api)" do
      it "builds a dedicated dependent preview first and injects its PLEK_SERVICE_*_URI into the parent" do
        preview = create(:preview, app_name: "whitehall", branch: "my-branch")
        allow(ConfigOverrides).to receive(:new).and_return(instance_double(ConfigOverrides, write!: nil))
        allow(PortAllocator).to receive(:allocate).and_return(20_000, 20_001)
        allow(DatabaseRunner).to receive(:new).and_return(instance_double(DatabaseRunner, start!: "mysql2://db/app_preview"))
        allow(Checkout).to receive(:new).and_return(instance_double(Checkout, checkout!: checkout_path))

        docker = instance_double(
          DockerRunner, build!: nil, start!: "container-123", migrate!: nil, seed!: nil,
                        container_name: "govuk-preview-app-#{preview.slug}"
        )
        allow(DockerRunner).to receive(:new) do |p|
          if p.id == preview.id
            docker
          else
            instance_double(
              DockerRunner, build!: nil, start!: "dep-container", migrate!: nil, seed!: nil,
                            container_name: "govuk-preview-app-#{p.slug}"
            )
          end
        end

        described_class.new(preview).build!

        dependent = preview.reload.dependents.sole
        expect(dependent).to have_attributes(app_name: "publishing-api", branch: "main", status: "running")

        expect(docker).to have_received(:start!).with(
          extra_env: hash_including("PLEK_SERVICE_PUBLISHING_API_URI" => "http://govuk-preview-app-#{dependent.slug}:#{dependent.port}"),
          publish_port: true,
        )
        expect(preview.reload.status).to eq("running")
      end

      it "does not publish a host port for the dependent, only for the parent" do
        preview = create(:preview, app_name: "whitehall", branch: "my-branch")
        allow(ConfigOverrides).to receive(:new).and_return(instance_double(ConfigOverrides, write!: nil))
        allow(PortAllocator).to receive(:allocate).and_return(20_000, 20_001)
        allow(DatabaseRunner).to receive(:new).and_return(instance_double(DatabaseRunner, start!: "url"))
        allow(Checkout).to receive(:new).and_return(instance_double(Checkout, checkout!: checkout_path))

        parent_docker = instance_double(
          DockerRunner, build!: nil, start!: "parent-container", migrate!: nil, seed!: nil,
                        container_name: "parent-container-name"
        )
        dependent_docker = instance_double(
          DockerRunner, build!: nil, start!: "dep-container", migrate!: nil, seed!: nil,
                        container_name: "dep-container-name"
        )
        allow(DockerRunner).to receive(:new) { |p| p.parent_id.nil? ? parent_docker : dependent_docker }

        described_class.new(preview).build!

        expect(dependent_docker).to have_received(:start!).with(hash_including(publish_port: false))
        expect(parent_docker).to have_received(:start!).with(hash_including(publish_port: true))
      end

      it "marks the parent failed with a distinct message when the dependency fails, without touching the dependency's own message" do
        preview = create(:preview, app_name: "whitehall", branch: "my-branch")
        allow(Checkout).to receive(:new).and_raise(Checkout::GitError, "fatal: could not clone publishing-api")

        described_class.new(preview).build!

        dependent = preview.reload.dependents.sole
        expect(dependent).to have_attributes(status: "failed", status_message: "fatal: could not clone publishing-api")
        expect(preview.status).to eq("failed")
        expect(preview.status_message).to include("dependency publishing-api failed to start")
        expect(preview.status_message).not_to eq(dependent.status_message)
      end
    end
  end
end

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
      DockerRunner, build!: nil, start!: start_result, migrate!: nil, seed!: nil, run_setup_task!: nil, start_worker!: nil,
                    container_name: "govuk-preview-app-#{preview.slug}"
    )
    allow(DockerRunner).to receive(:new).with(preview).and_return(docker)
    docker
  end

  # A generic double for a dependent preview this test isn't itself
  # asserting on (e.g. content-store, nested two levels under whitehall via
  # publishing-api) - stubs every DockerRunner method any manifest entry
  # might trigger, so it doesn't matter which app actually ends up using it.
  def generic_dependent_docker(preview)
    instance_double(
      DockerRunner, build!: nil, start!: "dep-container", migrate!: nil, seed!: nil, run_setup_task!: nil, start_worker!: nil,
                    container_name: "govuk-preview-app-#{preview.slug}"
    )
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

    context "with an app that has a database and dependencies of its own (publishing-api -> content-store, draft-content-store)" do
      it "starts a database, migrates with its URL, passes DATABASE_URL and both dependencies' PLEK URIs, and starts the worker" do
        preview = create(:preview, app_name: "publishing-api", branch: "my-branch")
        allow(ConfigOverrides).to receive(:new).and_return(instance_double(ConfigOverrides, write!: nil))
        allow(Checkout).to receive(:new) { instance_double(Checkout, checkout!: checkout_path) }
        allow(PortAllocator).to receive(:allocate).and_return(20_456, 20_457, 20_458)
        allow(DatabaseRunner).to receive(:new).and_return(instance_double(DatabaseRunner, start!: "postgresql://db/app_preview"))

        docker = instance_double(
          DockerRunner, build!: nil, start!: "container-123", migrate!: nil, seed!: nil, run_setup_task!: nil, start_worker!: nil,
                        container_name: "govuk-preview-app-#{preview.slug}"
        )
        allow(DockerRunner).to receive(:new) { |p| p.id == preview.id ? docker : generic_dependent_docker(p) }

        described_class.new(preview).build!

        content_store = preview.reload.dependents.find_by!(app_name: "content-store")
        draft_content_store = preview.dependents.find_by!(app_name: "draft-content-store")

        expect(docker).to have_received(:migrate!).with(extra_env: hash_including("DATABASE_URL" => "postgresql://db/app_preview"))
        expect(docker).to have_received(:start!).with(
          extra_env: hash_including(
            "DATABASE_URL" => "postgresql://db/app_preview",
            "PLEK_SERVICE_CONTENT_STORE_URI" => "http://govuk-preview-app-#{content_store.slug}:#{content_store.port}",
            "PLEK_SERVICE_DRAFT_CONTENT_STORE_URI" => "http://govuk-preview-app-#{draft_content_store.slug}:#{draft_content_store.port}",
          ),
          publish_port: true,
        )
        expect(docker).to have_received(:start_worker!).with(extra_env: hash_including("DATABASE_URL" => "postgresql://db/app_preview"))
        expect(preview.reload.status).to eq("running")
      end

      it "marks the preview failed when seeding fails, without starting the worker" do
        preview = create(:preview, app_name: "publishing-api", branch: "my-branch")
        allow(ConfigOverrides).to receive(:new).and_return(instance_double(ConfigOverrides, write!: nil))
        allow(Checkout).to receive(:new) { instance_double(Checkout, checkout!: checkout_path) }
        allow(PortAllocator).to receive(:allocate).and_return(20_456, 20_457, 20_458)
        allow(DatabaseRunner).to receive(:new).and_return(instance_double(DatabaseRunner, start!: "postgresql://db/app_preview"))

        docker = instance_double(
          DockerRunner, build!: nil, start!: nil, migrate!: nil, run_setup_task!: nil, start_worker!: nil,
                        container_name: "govuk-preview-app-#{preview.slug}"
        )
        allow(docker).to receive(:seed!).and_raise(DockerRunner::DockerError, "boom")
        allow(DockerRunner).to receive(:new) { |p| p.id == preview.id ? docker : generic_dependent_docker(p) }

        described_class.new(preview).build!

        expect(docker).not_to have_received(:start!)
        expect(docker).not_to have_received(:start_worker!)
        expect(preview.reload).to have_attributes(status: "failed", status_message: "boom")
      end
    end

    context "with an app that has multiple dependencies (whitehall -> publishing-api -> content-store/draft-content-store, frontend, draft-frontend)" do
      it "builds a dedicated dependent preview first and injects its PLEK_SERVICE_*_URI into the parent" do
        preview = create(:preview, app_name: "whitehall", branch: "my-branch")
        allow(ConfigOverrides).to receive(:new).and_return(instance_double(ConfigOverrides, write!: nil))
        allow(PortAllocator).to receive(:allocate).and_return(20_000, 20_001, 20_002, 20_003, 20_004, 20_005)
        allow(DatabaseRunner).to receive(:new).and_return(instance_double(DatabaseRunner, start!: "mysql2://db/app_preview"))
        allow(Checkout).to receive(:new).and_return(instance_double(Checkout, checkout!: checkout_path))

        docker = instance_double(
          DockerRunner, build!: nil, start!: "container-123", migrate!: nil, seed!: nil, run_setup_task!: nil, start_worker!: nil,
                        container_name: "govuk-preview-app-#{preview.slug}"
        )
        allow(DockerRunner).to receive(:new) { |p| p.id == preview.id ? docker : generic_dependent_docker(p) }

        described_class.new(preview).build!

        dependent = preview.reload.dependents.find_by!(app_name: "publishing-api")
        expect(dependent).to have_attributes(app_name: "publishing-api", branch: "main", status: "running")

        expect(docker).to have_received(:start!).with(
          extra_env: hash_including("PLEK_SERVICE_PUBLISHING_API_URI" => "http://govuk-preview-app-#{dependent.slug}:#{dependent.port}"),
          publish_port: true,
        )
        expect(preview.reload.status).to eq("running")
      end

      it "builds the dependency's own dependencies too (content-store/draft-content-store, two levels down)" do
        preview = create(:preview, app_name: "whitehall", branch: "my-branch")
        allow(ConfigOverrides).to receive(:new).and_return(instance_double(ConfigOverrides, write!: nil))
        allow(PortAllocator).to receive(:allocate).and_return(20_000, 20_001, 20_002, 20_003, 20_004, 20_005)
        allow(DatabaseRunner).to receive(:new).and_return(instance_double(DatabaseRunner, start!: "db-url"))
        allow(Checkout).to receive(:new).and_return(instance_double(Checkout, checkout!: checkout_path))
        allow(DockerRunner).to receive(:new) { |p| generic_dependent_docker(p) }

        described_class.new(preview).build!

        publishing_api = preview.reload.dependents.find_by!(app_name: "publishing-api")
        content_store = publishing_api.dependents.find_by!(app_name: "content-store")
        draft_content_store = publishing_api.dependents.find_by!(app_name: "draft-content-store")
        expect(content_store).to have_attributes(branch: "main", status: "running")
        expect(draft_content_store).to have_attributes(branch: "main", status: "running")
      end

      it "gives frontend the real local Content Store URI resolved by its sibling publishing-api dependency, not frontend's own real-GOV.UK default" do
        preview = create(:preview, app_name: "whitehall", branch: "my-branch")
        allow(ConfigOverrides).to receive(:new).and_return(instance_double(ConfigOverrides, write!: nil))
        allow(PortAllocator).to receive(:allocate).and_return(20_000, 20_001, 20_002, 20_003, 20_004, 20_005)
        allow(DatabaseRunner).to receive(:new).and_return(instance_double(DatabaseRunner, start!: "db-url"))
        allow(Checkout).to receive(:new).and_return(instance_double(Checkout, checkout!: checkout_path))

        dependent_dockers = Hash.new { |h, p| h[p] = generic_dependent_docker(p) }
        allow(DockerRunner).to receive(:new) { |p| p.parent_id.nil? ? generic_dependent_docker(p) : dependent_dockers[p] }

        described_class.new(preview).build!

        publishing_api = preview.reload.dependents.find_by!(app_name: "publishing-api")
        content_store = publishing_api.dependents.find_by!(app_name: "content-store")
        frontend = preview.reload.dependents.find_by!(app_name: "frontend")

        expect(dependent_dockers[frontend]).to have_received(:start!).with(
          extra_env: hash_including("PLEK_SERVICE_CONTENT_STORE_URI" => "http://govuk-preview-app-#{content_store.slug}:#{content_store.port}"),
          publish_port: false,
        )
      end

      it "gives draft-frontend the draft Content Store's address under the same key frontend uses, via env_aliases - not the live one" do
        preview = create(:preview, app_name: "whitehall", branch: "my-branch")
        allow(ConfigOverrides).to receive(:new).and_return(instance_double(ConfigOverrides, write!: nil))
        allow(PortAllocator).to receive(:allocate).and_return(20_000, 20_001, 20_002, 20_003, 20_004, 20_005)
        allow(DatabaseRunner).to receive(:new).and_return(instance_double(DatabaseRunner, start!: "db-url"))
        allow(Checkout).to receive(:new).and_return(instance_double(Checkout, checkout!: checkout_path))

        dependent_dockers = Hash.new { |h, p| h[p] = generic_dependent_docker(p) }
        allow(DockerRunner).to receive(:new) { |p| p.parent_id.nil? ? generic_dependent_docker(p) : dependent_dockers[p] }

        described_class.new(preview).build!

        publishing_api = preview.reload.dependents.find_by!(app_name: "publishing-api")
        content_store = publishing_api.dependents.find_by!(app_name: "content-store")
        draft_content_store = publishing_api.dependents.find_by!(app_name: "draft-content-store")
        draft_frontend = preview.reload.dependents.find_by!(app_name: "draft-frontend")

        expect(dependent_dockers[draft_frontend]).to have_received(:start!).with(
          extra_env: hash_including(
            "PLEK_SERVICE_CONTENT_STORE_URI" => "http://govuk-preview-app-#{draft_content_store.slug}:#{draft_content_store.port}",
          ),
          publish_port: false,
        )
        expect(dependent_dockers[draft_frontend]).not_to have_received(:start!).with(
          extra_env: hash_including(
            "PLEK_SERVICE_CONTENT_STORE_URI" => "http://govuk-preview-app-#{content_store.slug}:#{content_store.port}",
          ),
          publish_port: false,
        )
      end

      it "gives whitehall the real, browser-reachable public URLs for frontend and draft-frontend, not their internal container addresses" do
        preview = create(:preview, app_name: "whitehall", branch: "my-branch")
        allow(ConfigOverrides).to receive(:new).and_return(instance_double(ConfigOverrides, write!: nil))
        allow(PortAllocator).to receive(:allocate).and_return(20_000, 20_001, 20_002, 20_003, 20_004, 20_005)
        allow(DatabaseRunner).to receive(:new).and_return(instance_double(DatabaseRunner, start!: "db-url"))
        allow(Checkout).to receive(:new).and_return(instance_double(Checkout, checkout!: checkout_path))

        docker = instance_double(
          DockerRunner, build!: nil, start!: "container-123", migrate!: nil, seed!: nil, run_setup_task!: nil, start_worker!: nil,
                        container_name: "govuk-preview-app-#{preview.slug}"
        )
        allow(DockerRunner).to receive(:new) { |p| p.id == preview.id ? docker : generic_dependent_docker(p) }

        described_class.new(preview).build!

        frontend = preview.reload.dependents.find_by!(app_name: "frontend")
        draft_frontend = preview.dependents.find_by!(app_name: "draft-frontend")

        expect(docker).to have_received(:start!).with(
          extra_env: hash_including(
            "PLEK_SERVICE_FRONTEND_PUBLIC_URL" => frontend.url,
            "PLEK_SERVICE_DRAFT_FRONTEND_PUBLIC_URL" => draft_frontend.url,
          ),
          publish_port: true,
        )
      end

      it "does not inject a _PUBLIC_URL for a dependency that isn't publicly_readable" do
        preview = create(:preview, app_name: "whitehall", branch: "my-branch")
        allow(ConfigOverrides).to receive(:new).and_return(instance_double(ConfigOverrides, write!: nil))
        allow(PortAllocator).to receive(:allocate).and_return(20_000, 20_001, 20_002, 20_003, 20_004, 20_005)
        allow(DatabaseRunner).to receive(:new).and_return(instance_double(DatabaseRunner, start!: "db-url"))
        allow(Checkout).to receive(:new).and_return(instance_double(Checkout, checkout!: checkout_path))

        docker = instance_double(
          DockerRunner, build!: nil, start!: "container-123", migrate!: nil, seed!: nil, run_setup_task!: nil, start_worker!: nil,
                        container_name: "govuk-preview-app-#{preview.slug}"
        )
        allow(DockerRunner).to receive(:new) { |p| p.id == preview.id ? docker : generic_dependent_docker(p) }

        described_class.new(preview).build!

        expect(docker).to have_received(:start!).with(
          extra_env: hash_excluding("PLEK_SERVICE_PUBLISHING_API_PUBLIC_URL"),
          publish_port: true,
        )
      end

      it "does not publish a host port for any dependency, only for the top-level preview" do
        preview = create(:preview, app_name: "whitehall", branch: "my-branch")
        allow(ConfigOverrides).to receive(:new).and_return(instance_double(ConfigOverrides, write!: nil))
        allow(PortAllocator).to receive(:allocate).and_return(20_000, 20_001, 20_002, 20_003, 20_004, 20_005)
        allow(DatabaseRunner).to receive(:new).and_return(instance_double(DatabaseRunner, start!: "url"))
        allow(Checkout).to receive(:new).and_return(instance_double(Checkout, checkout!: checkout_path))

        parent_docker = instance_double(
          DockerRunner, build!: nil, start!: "parent-container", migrate!: nil, seed!: nil, run_setup_task!: nil, start_worker!: nil,
                        container_name: "parent-container-name"
        )
        # Memoized by preview (not just created fresh per call) so the exact
        # same double is returned every time DockerRunner.new(same_preview)
        # is called, and later assertions see the real interactions.
        dependent_dockers = Hash.new { |h, p| h[p] = generic_dependent_docker(p) }
        allow(DockerRunner).to receive(:new) { |p| p.parent_id.nil? ? parent_docker : dependent_dockers[p] }

        described_class.new(preview).build!

        publishing_api = preview.reload.dependents.find_by!(app_name: "publishing-api")
        content_store = publishing_api.dependents.find_by!(app_name: "content-store")
        draft_content_store = publishing_api.dependents.find_by!(app_name: "draft-content-store")
        frontend = preview.reload.dependents.find_by!(app_name: "frontend")
        draft_frontend = preview.dependents.find_by!(app_name: "draft-frontend")

        [publishing_api, content_store, draft_content_store, frontend, draft_frontend].each do |dependent|
          expect(dependent_dockers[dependent]).to have_received(:start!).with(hash_including(publish_port: false))
        end
        expect(parent_docker).to have_received(:start!).with(hash_including(publish_port: true))
      end

      it "marks the parent failed with a distinct message when the dependency fails, without touching the dependency's own message" do
        preview = create(:preview, app_name: "whitehall", branch: "my-branch")
        allow(ConfigOverrides).to receive(:new).and_return(instance_double(ConfigOverrides, write!: nil))
        allow(PortAllocator).to receive(:allocate).and_return(20_000, 20_001, 20_002, 20_003, 20_004, 20_005)
        allow(DatabaseRunner).to receive(:new).and_return(instance_double(DatabaseRunner, start!: "db-url"))
        allow(DockerRunner).to receive(:new) { |p| generic_dependent_docker(p) }
        allow(Checkout).to receive(:new) do |p|
          if p.app_name == "publishing-api"
            checkout = instance_double(Checkout)
            allow(checkout).to receive(:checkout!).and_raise(Checkout::GitError, "fatal: could not clone publishing-api")
            checkout
          else
            instance_double(Checkout, checkout!: checkout_path)
          end
        end

        described_class.new(preview).build!

        dependent = preview.reload.dependents.find_by!(app_name: "publishing-api")
        expect(dependent).to have_attributes(status: "failed", status_message: "fatal: could not clone publishing-api")
        expect(preview.status).to eq("failed")
        expect(preview.status_message).to include("dependency publishing-api failed to start")
        expect(preview.status_message).not_to eq(dependent.status_message)
        # publishing-api, whitehall's first declared dependency, fails before
        # frontend (declared after it) is ever attempted.
        expect(preview.reload.dependents.pluck(:app_name)).to eq(%w[publishing-api])
      end
    end

    context "with an app that has setup_tasks (whitehall)" do
      it "runs each configured task, in order, after seeding" do
        preview = create(:preview, app_name: "whitehall", branch: "my-branch")
        allow(ConfigOverrides).to receive(:new).and_return(instance_double(ConfigOverrides, write!: nil))
        allow(PortAllocator).to receive(:allocate).and_return(20_000, 20_001, 20_002, 20_003, 20_004, 20_005)
        allow(DatabaseRunner).to receive(:new).and_return(instance_double(DatabaseRunner, start!: "mysql2://db/app_preview"))
        allow(Checkout).to receive(:new).and_return(instance_double(Checkout, checkout!: checkout_path))

        docker = instance_double(
          DockerRunner, build!: nil, start!: "container-123", migrate!: nil, seed!: nil, run_setup_task!: nil, start_worker!: nil,
                        container_name: "govuk-preview-app-whitehall-my-branch"
        )
        allow(DockerRunner).to receive(:new) { |p| p.app_name == "whitehall" ? docker : generic_dependent_docker(p) }

        described_class.new(preview).build!

        expect(docker).to have_received(:run_setup_task!).with("taxonomy:populate_end_to_end_test_data", extra_env: anything).ordered
        expect(docker).to have_received(:run_setup_task!).with("taxonomy:rebuild_cache", extra_env: anything).ordered
        expect(preview.reload.status).to eq("running")
      end

      it "marks the preview failed when a setup task fails, without running later tasks" do
        preview = create(:preview, app_name: "whitehall", branch: "my-branch")
        allow(ConfigOverrides).to receive(:new).and_return(instance_double(ConfigOverrides, write!: nil))
        allow(PortAllocator).to receive(:allocate).and_return(20_000, 20_001, 20_002, 20_003, 20_004, 20_005)
        allow(DatabaseRunner).to receive(:new).and_return(instance_double(DatabaseRunner, start!: "mysql2://db/app_preview"))
        allow(Checkout).to receive(:new).and_return(instance_double(Checkout, checkout!: checkout_path))

        docker = instance_double(
          DockerRunner, build!: nil, start!: nil, migrate!: nil, seed!: nil, start_worker!: nil,
                        container_name: "govuk-preview-app-whitehall-my-branch"
        )
        allow(docker).to receive(:run_setup_task!)
          .with("taxonomy:populate_end_to_end_test_data", extra_env: anything)
          .and_raise(DockerRunner::DockerError, "base_path did not conform to standard")
        allow(DockerRunner).to receive(:new) { |p| p.app_name == "whitehall" ? docker : generic_dependent_docker(p) }

        described_class.new(preview).build!

        expect(docker).not_to have_received(:run_setup_task!).with("taxonomy:rebuild_cache", extra_env: anything)
        expect(docker).not_to have_received(:start!)
        expect(preview.reload).to have_attributes(status: "failed", status_message: "base_path did not conform to standard")
      end
    end
  end
end

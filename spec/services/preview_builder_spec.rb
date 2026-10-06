require "rails_helper"

RSpec.describe PreviewBuilder do
  # Memoized per preview, so the exact same double is returned every time
  # KubernetesRunner.new(same_preview, ...) is called - both when the
  # builder starts it and when a parent looks up its container name - and
  # later assertions see the real interactions.
  let(:runners) do
    Hash.new do |hash, preview|
      hash[preview] = instance_double(
        KubernetesRunner, prepare!: nil, start!: "deploy-uid", migrate!: nil, seed!: nil, run_setup_task!: nil, start_worker!: nil,
                          container_name: "govuk-preview-app-#{preview.slug}"
      )
    end
  end

  before do
    allow(ImageResolver).to receive(:new) do |app, branch|
      instance_double(ImageResolver, resolve!: "ghcr.io/alphagov/govuk/#{app.name}:#{branch}")
    end
    allow(KubernetesRunner).to receive(:new) { |preview, **| runners[preview] }
  end

  def stub_databases(url = "db-url")
    allow(KubernetesDatabaseRunner).to receive(:new).and_return(instance_double(KubernetesDatabaseRunner, start!: url))
  end

  def internal_uri(preview)
    "http://govuk-preview-app-#{preview.slug}"
  end

  describe "#build!" do
    it "does nothing if the preview is already running" do
      preview = create(:preview, app_name: "frontend", branch: "my-branch", status: :running)

      described_class.new(preview).build!

      expect(ImageResolver).not_to have_received(:new)
    end

    context "with an app that has no dependencies or database (frontend)" do
      it "resolves the branch's prebuilt image, prepares and starts it, and marks the preview running" do
        preview = create(:preview, app_name: "frontend", branch: "my-branch")

        described_class.new(preview).build!

        expect(ImageResolver).to have_received(:new).with(GovukApps.find("frontend"), "my-branch")
        expect(KubernetesRunner).to have_received(:new).with(preview, image: "ghcr.io/alphagov/govuk/frontend:my-branch")
        expect(runners[preview]).to have_received(:prepare!)
        expect(runners[preview]).to have_received(:start!).with(extra_env: {})
        expect(preview.reload).to have_attributes(status: "running", container_id: "deploy-uid")
      end

      it "marks the preview failed with the error message when its image never appears" do
        preview = create(:preview, app_name: "frontend", branch: "my-branch")
        resolver = instance_double(ImageResolver)
        allow(resolver).to receive(:resolve!).and_raise(ImageResolver::ImageError, "No image was published")
        allow(ImageResolver).to receive(:new).and_return(resolver)

        described_class.new(preview).build!

        expect(preview.reload).to have_attributes(status: "failed", status_message: "No image was published")
      end

      it "marks the preview failed when Kubernetes rejects something" do
        preview = create(:preview, app_name: "frontend", branch: "my-branch")
        allow(runners[preview]).to receive(:start!).and_raise(KubernetesApi::Error, "deployments is forbidden")

        described_class.new(preview).build!

        expect(preview.reload).to have_attributes(status: "failed", status_message: "deployments is forbidden")
      end
    end

    context "with an app that has a database and dependencies of its own (publishing-api -> content-store, draft-content-store)" do
      it "starts a database, migrates with its URL, passes DATABASE_URL and both dependencies' PLEK URIs, and starts the worker" do
        preview = create(:preview, app_name: "publishing-api", branch: "my-branch")
        stub_databases("postgresql://db/app_preview")

        described_class.new(preview).build!

        content_store = preview.reload.dependents.find_by!(app_name: "content-store")
        draft_content_store = preview.dependents.find_by!(app_name: "draft-content-store")
        runner = runners[preview]

        expect(runner).to have_received(:migrate!).with(extra_env: hash_including("DATABASE_URL" => "postgresql://db/app_preview"))
        expect(runner).to have_received(:start!).with(
          extra_env: hash_including(
            "DATABASE_URL" => "postgresql://db/app_preview",
            "PLEK_SERVICE_CONTENT_STORE_URI" => internal_uri(content_store),
            "PLEK_SERVICE_DRAFT_CONTENT_STORE_URI" => internal_uri(draft_content_store),
          ),
        )
        expect(runner).to have_received(:start_worker!).with(extra_env: hash_including("DATABASE_URL" => "postgresql://db/app_preview"))
        expect(preview.reload.status).to eq("running")
      end

      it "marks the preview failed when seeding fails, without starting the worker" do
        preview = create(:preview, app_name: "publishing-api", branch: "my-branch")
        stub_databases("postgresql://db/app_preview")
        allow(runners[preview]).to receive(:seed!).and_raise(KubernetesRunner::KubernetesError, "boom")

        described_class.new(preview).build!

        expect(runners[preview]).not_to have_received(:start!)
        expect(runners[preview]).not_to have_received(:start_worker!)
        expect(preview.reload).to have_attributes(status: "failed", status_message: "boom")
      end
    end

    context "with an app that has multiple dependencies (whitehall -> publishing-api -> content-store/draft-content-store, frontend, draft-frontend)" do
      before { stub_databases }

      it "builds a dedicated dependent preview, on main, first and injects its PLEK_SERVICE_*_URI into the parent" do
        preview = create(:preview, app_name: "whitehall", branch: "my-branch")

        described_class.new(preview).build!

        dependent = preview.reload.dependents.find_by!(app_name: "publishing-api")
        expect(dependent).to have_attributes(app_name: "publishing-api", branch: "main", status: "running")
        expect(ImageResolver).to have_received(:new).with(GovukApps.find("publishing-api"), "main")

        expect(runners[preview]).to have_received(:start!).with(
          extra_env: hash_including("PLEK_SERVICE_PUBLISHING_API_URI" => internal_uri(dependent)),
        )
        expect(preview.reload.status).to eq("running")
      end

      it "builds the dependency's own dependencies too (content-store/draft-content-store, two levels down)" do
        preview = create(:preview, app_name: "whitehall", branch: "my-branch")

        described_class.new(preview).build!

        publishing_api = preview.reload.dependents.find_by!(app_name: "publishing-api")
        expect(publishing_api.dependents.find_by!(app_name: "content-store")).to have_attributes(branch: "main", status: "running")
        expect(publishing_api.dependents.find_by!(app_name: "draft-content-store")).to have_attributes(branch: "main", status: "running")
      end

      it "gives frontend the real local Content Store URI resolved by its sibling publishing-api dependency, not frontend's own real-GOV.UK default" do
        preview = create(:preview, app_name: "whitehall", branch: "my-branch")

        described_class.new(preview).build!

        content_store = preview.reload.dependents.find_by!(app_name: "publishing-api").dependents.find_by!(app_name: "content-store")
        frontend = preview.dependents.find_by!(app_name: "frontend")

        expect(runners[frontend]).to have_received(:start!).with(
          extra_env: hash_including("PLEK_SERVICE_CONTENT_STORE_URI" => internal_uri(content_store)),
        )
      end

      it "gives draft-frontend the draft Content Store's address under the same key frontend uses, via env_aliases - not the live one" do
        preview = create(:preview, app_name: "whitehall", branch: "my-branch")

        described_class.new(preview).build!

        publishing_api = preview.reload.dependents.find_by!(app_name: "publishing-api")
        content_store = publishing_api.dependents.find_by!(app_name: "content-store")
        draft_content_store = publishing_api.dependents.find_by!(app_name: "draft-content-store")
        draft_frontend = preview.dependents.find_by!(app_name: "draft-frontend")

        expect(runners[draft_frontend]).to have_received(:start!).with(
          extra_env: hash_including("PLEK_SERVICE_CONTENT_STORE_URI" => internal_uri(draft_content_store)),
        )
        expect(runners[draft_frontend]).not_to have_received(:start!).with(
          extra_env: hash_including("PLEK_SERVICE_CONTENT_STORE_URI" => internal_uri(content_store)),
        )
      end

      it "gives whitehall the real, browser-reachable public URLs for frontend and draft-frontend, not their internal addresses" do
        preview = create(:preview, app_name: "whitehall", branch: "my-branch")

        described_class.new(preview).build!

        frontend = preview.reload.dependents.find_by!(app_name: "frontend")
        draft_frontend = preview.dependents.find_by!(app_name: "draft-frontend")

        expect(runners[preview]).to have_received(:start!).with(
          extra_env: hash_including(
            "PLEK_SERVICE_FRONTEND_PUBLIC_URL" => frontend.url,
            "PLEK_SERVICE_DRAFT_FRONTEND_PUBLIC_URL" => draft_frontend.url,
          ),
        )
      end

      it "does not inject a _PUBLIC_URL for a dependency that isn't publicly_readable" do
        preview = create(:preview, app_name: "whitehall", branch: "my-branch")

        described_class.new(preview).build!

        expect(runners[preview]).to have_received(:start!).with(
          extra_env: hash_excluding("PLEK_SERVICE_PUBLISHING_API_PUBLIC_URL"),
        )
      end

      it "marks the parent failed with a distinct message when the dependency fails, without touching the dependency's own message" do
        preview = create(:preview, app_name: "whitehall", branch: "my-branch")
        allow(ImageResolver).to receive(:new) do |app, branch|
          resolver = instance_double(ImageResolver, resolve!: "ghcr.io/alphagov/govuk/#{app.name}:#{branch}")
          if app.name == "publishing-api"
            allow(resolver).to receive(:resolve!).and_raise(ImageResolver::ImageError, "No image for publishing-api")
          end
          resolver
        end

        described_class.new(preview).build!

        dependent = preview.reload.dependents.find_by!(app_name: "publishing-api")
        expect(dependent).to have_attributes(status: "failed", status_message: "No image for publishing-api")
        expect(preview.status).to eq("failed")
        expect(preview.status_message).to include("dependency publishing-api failed to start")
        expect(preview.status_message).not_to eq(dependent.status_message)
        # publishing-api, whitehall's first declared dependency, fails before
        # frontend (declared after it) is ever attempted.
        expect(preview.reload.dependents.pluck(:app_name)).to eq(%w[publishing-api])
      end
    end

    context "with an app that has setup_tasks (whitehall)" do
      before { stub_databases("mysql2://db/app_preview") }

      it "runs each configured task, in order, after seeding" do
        preview = create(:preview, app_name: "whitehall", branch: "my-branch")

        described_class.new(preview).build!

        expect(runners[preview]).to have_received(:run_setup_task!).with("taxonomy:populate_end_to_end_test_data", extra_env: anything).ordered
        expect(runners[preview]).to have_received(:run_setup_task!).with("taxonomy:rebuild_cache", extra_env: anything).ordered
        expect(preview.reload.status).to eq("running")
      end

      it "marks the preview failed when a setup task fails, without running later tasks" do
        preview = create(:preview, app_name: "whitehall", branch: "my-branch")
        allow(runners[preview]).to receive(:run_setup_task!)
          .with("taxonomy:populate_end_to_end_test_data", extra_env: anything)
          .and_raise(KubernetesRunner::KubernetesError, "base_path did not conform to standard")

        described_class.new(preview).build!

        expect(runners[preview]).not_to have_received(:run_setup_task!).with("taxonomy:rebuild_cache", extra_env: anything)
        expect(runners[preview]).not_to have_received(:start!)
        expect(preview.reload).to have_attributes(status: "failed", status_message: "base_path did not conform to standard")
      end
    end
  end
end

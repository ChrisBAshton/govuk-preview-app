require "rails_helper"

RSpec.describe "Previews" do
  let(:user) { create(:user) }

  before { login_as(user) }

  describe "GET /previews" do
    it "succeeds and lists existing previews" do
      preview = create(:preview, app_name: "frontend", branch: "my-branch")

      get previews_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("frontend")
      expect(response.body).to include(preview.branch)
    end

    it "shows the Dashboard/Switch app navigation" do
      get previews_path

      expect(response.body).to include(">Dashboard<")
      expect(response.body).to include(">Switch app<")
    end

    it "links a publicly_readable dependency at its own public hostname, rather than showing it as internal-only" do
      parent = create(:preview, app_name: "publishing-api", branch: "my-branch", status: :running)
      dependent = create(:preview, app_name: "content-store", branch: "main", parent: parent, status: :running)

      get previews_path

      expect(response.body).to include(dependent.hostname)
      expect(response.body).not_to include("Internal dependency")
    end

    it "shows an unroutable dependency as an internal dependency, with no link" do
      parent = create(:preview, app_name: "whitehall", branch: "my-branch", status: :running)
      create(:preview, app_name: "publishing-api", branch: "main", parent: parent, status: :running)

      get previews_path

      expect(response.body).to include("Internal dependency")
    end

    it "nests each dependent directly beneath the app it belongs to, however deep the chain" do
      # Created first, so it's the *older* top-level preview - the
      # controller orders top-level previews newest-first, so this must
      # still end up listed after the whole whitehall chain below.
      other_top_level = create(:preview, app_name: "frontend", branch: "another-branch", status: :running)
      whitehall = create(:preview, app_name: "whitehall", branch: "my-branch", status: :running)
      publishing_api = create(:preview, app_name: "publishing-api", branch: "main", parent: whitehall, status: :running)
      content_store = create(:preview, app_name: "content-store", branch: "main", parent: publishing_api, status: :running)

      get previews_path

      row_texts = Capybara::Node::Simple.new(response.body).all("table tbody tr").map(&:text)
      positions = [whitehall, publishing_api, content_store, other_top_level].index_with do |preview|
        row_texts.index { |text| text.include?(preview.app_name) }
      end

      expect(positions[whitehall]).to be < positions[publishing_api]
      expect(positions[publishing_api]).to be < positions[content_store]
      expect(positions[content_store]).to be < positions[other_top_level]
    end
  end

  describe "GET /previews/new" do
    it "succeeds" do
      get new_preview_path

      expect(response).to have_http_status(:ok)
    end
  end

  describe "POST /previews" do
    it "creates a preview and queues the create job" do
      expect {
        post previews_path, params: { preview: { app_name: "frontend", branch: "my-branch" } }
      }.to change(Preview, :count).by(1).and change(PreviewsCreateJob.jobs, :size).by(1)

      expect(response).to redirect_to(previews_path)
      expect(Preview.last).to have_attributes(app_name: "frontend", branch: "my-branch", status: "queued")
    end

    it "re-renders the form with errors for an unknown app" do
      expect {
        post previews_path, params: { preview: { app_name: "not-a-real-app", branch: "my-branch" } }
      }.not_to change(Preview, :count)

      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "DELETE /previews/:id" do
    it "marks the preview as stopping and queues the destroy job" do
      preview = create(:preview, app_name: "frontend", branch: "my-branch", status: :running)

      expect {
        delete preview_path(preview)
      }.to change(PreviewsDestroyJob.jobs, :size).by(1)

      expect(response).to redirect_to(previews_path)
      expect(preview.reload.status).to eq("stopping")
    end
  end
end

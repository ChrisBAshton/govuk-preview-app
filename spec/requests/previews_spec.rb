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

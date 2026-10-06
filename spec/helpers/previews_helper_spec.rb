require "rails_helper"

RSpec.describe PreviewsHelper do
  describe "#previews_with_dependencies" do
    it "lists a top-level preview on its own when it has no dependencies" do
      previews = [create(:preview, app_name: "frontend", branch: "my-branch")]

      expect(helper.previews_with_dependencies(previews)).to eq([[previews.first, false]])
    end

    it "lists every dependency in the stack one level beneath it, in build order, however they're chained" do
      parent = create(:preview, app_name: "whitehall", branch: "my-branch")
      publishing_api = create(:preview, app_name: "publishing-api", branch: "main", parent: parent, created_at: 3.minutes.ago)
      content_store = create(:preview, app_name: "content-store", branch: "main", parent: publishing_api, created_at: 4.minutes.ago)
      frontend = create(:preview, app_name: "frontend", branch: "main", parent: parent, created_at: 1.minute.ago)

      expect(helper.previews_with_dependencies([parent])).to eq(
        [[parent, false], [content_store, true], [publishing_api, true], [frontend, true]],
      )
    end
  end

  describe "#preview_app_name_cell" do
    it "renders a top-level preview's app name plainly" do
      preview = create(:preview, app_name: "frontend", branch: "my-branch")

      expect(helper.preview_app_name_cell(preview, false)).to eq("frontend")
    end

    it "marks a dependency's app name" do
      preview = create(:preview, app_name: "publishing-api", branch: "main")

      expect(helper.preview_app_name_cell(preview, true)).to include("↳ publishing-api", "app-dependency-name")
    end
  end
end

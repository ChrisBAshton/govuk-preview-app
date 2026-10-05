require "rails_helper"

RSpec.describe PreviewsHelper do
  describe "#previews_with_depth" do
    it "pairs each top-level preview with depth 0" do
      previews = [create(:preview, app_name: "frontend", branch: "my-branch")]

      expect(helper.previews_with_depth(previews)).to eq([[previews.first, 0]])
    end

    it "nests a dependent directly after its parent, at depth + 1" do
      parent = create(:preview, app_name: "whitehall", branch: "my-branch")
      dependent = create(:preview, app_name: "publishing-api", branch: "main", parent: parent)

      expect(helper.previews_with_depth([parent])).to eq([[parent, 0], [dependent, 1]])
    end

    it "nests however many levels deep the chain goes" do
      parent = create(:preview, app_name: "whitehall", branch: "my-branch")
      dependent = create(:preview, app_name: "publishing-api", branch: "main", parent: parent)
      grandchild = create(:preview, app_name: "frontend", branch: "main", parent: dependent)

      expect(helper.previews_with_depth([parent])).to eq([[parent, 0], [dependent, 1], [grandchild, 2]])
    end
  end

  describe "#preview_app_name_cell" do
    it "renders a top-level preview's app name plainly" do
      preview = create(:preview, app_name: "frontend", branch: "my-branch")

      expect(helper.preview_app_name_cell(preview, 0)).to eq("frontend")
    end

    it "prefixes and indents a nested dependent's app name" do
      preview = create(:preview, app_name: "publishing-api", branch: "main")

      expect(helper.preview_app_name_cell(preview, 1)).to include("↳ publishing-api")
    end
  end
end

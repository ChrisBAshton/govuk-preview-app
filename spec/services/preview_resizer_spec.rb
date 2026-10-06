require "rails_helper"

RSpec.describe PreviewResizer do
  let(:builder) { instance_double(PreviewBuilder, build!: nil) }

  before do
    allow(PreviewBuilder).to receive(:new).and_return(builder)
    allow(PreviewCapacity).to receive(:make_room_for!)
  end

  context "when adding the full stack" do
    let(:root) { create(:preview, app_name: "whitehall", branch: "my-branch", status: :running) }

    it "makes room for it, then lets the builder add the extra apps and restart what's changed" do
      described_class.new(root).resize!(full_stack: true)

      expect(root.reload).to have_attributes(full_stack: true, status_message: nil)
      expect(PreviewCapacity).to have_received(:make_room_for!).with(root)
      expect(builder).to have_received(:build!)
    end

    it "stays a core stack, saying why, when there isn't room" do
      allow(PreviewCapacity).to receive(:make_room_for!).and_raise(PreviewCapacity::AtCapacityError, "At capacity: blah")

      described_class.new(root).resize!(full_stack: true)

      expect(root.reload).to have_attributes(full_stack: false, status_message: "Couldn't add the full stack: At capacity: blah")
      expect(builder).not_to have_received(:build!)
    end
  end

  context "when removing the full stack" do
    let(:root) { create(:preview, app_name: "whitehall", branch: "my-branch", status: :running, full_stack: true) }

    before do
      publishing_api = create(:preview, app_name: "publishing-api", branch: "main", parent: root, status: :running)
      create(:preview, app_name: "content-store", branch: "main", parent: publishing_api, status: :running)
      create(:preview, app_name: "frontend", branch: "main", parent: root, status: :running)
    end

    it "destroys only the full-stack-only previews, at any depth, then lets the builder repoint what remains" do
      destroyed = []
      allow(PreviewDestroyer).to receive(:new) { |preview| instance_double(PreviewDestroyer, destroy!: destroyed << preview.app_name) }

      described_class.new(root).resize!(full_stack: false)

      expect(destroyed).to contain_exactly("content-store", "frontend")
      expect(root.reload.full_stack).to be(false)
      expect(builder).to have_received(:build!)
    end
  end

  it "does nothing to a preview that isn't running" do
    root = create(:preview, app_name: "whitehall", branch: "my-branch", status: :sleeping)

    described_class.new(root).resize!(full_stack: true)

    expect(root.reload.full_stack).to be(false)
    expect(builder).not_to have_received(:build!)
  end
end

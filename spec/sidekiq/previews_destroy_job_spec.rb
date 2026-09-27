require "rails_helper"

RSpec.describe PreviewsDestroyJob do
  it "delegates to PreviewDestroyer for the given preview" do
    preview = create(:preview, app_name: "frontend", branch: "my-branch")
    destroyer = instance_double(PreviewDestroyer, destroy!: nil)
    allow(PreviewDestroyer).to receive(:new).with(preview).and_return(destroyer)

    described_class.new.perform(preview.id)

    expect(destroyer).to have_received(:destroy!)
  end
end

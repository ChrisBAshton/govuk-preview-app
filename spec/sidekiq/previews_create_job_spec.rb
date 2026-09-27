require "rails_helper"

RSpec.describe PreviewsCreateJob do
  it "delegates to PreviewBuilder for the given preview" do
    preview = create(:preview, app_name: "frontend", branch: "my-branch")
    builder = instance_double(PreviewBuilder, build!: nil)
    allow(PreviewBuilder).to receive(:new).with(preview).and_return(builder)

    described_class.new.perform(preview.id)

    expect(builder).to have_received(:build!)
  end
end

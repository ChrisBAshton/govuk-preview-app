require "rails_helper"

RSpec.describe Checkout do
  let(:preview) { create(:preview, app_name: "frontend", branch: "my-branch") }
  let(:checkout) { described_class.new(preview) }
  let(:tmp_root) { Pathname.new(Dir.mktmpdir) }

  before do
    allow(described_class).to receive(:root).and_return(tmp_root)
  end

  after { FileUtils.rm_rf(tmp_root) }

  describe "#path" do
    it "is under the checkout root, namespaced by app and slug" do
      expect(checkout.path).to eq(tmp_root.join("frontend", preview.slug))
    end
  end

  describe "#checkout!" do
    context "when the checkout doesn't already exist" do
      it "clones the app's repo at the requested branch" do
        allow(Open3).to receive(:capture3).and_return(["", "", instance_double(Process::Status, success?: true)])

        checkout.checkout!

        expect(Open3).to have_received(:capture3).with(
          "git", "clone", "--branch", "my-branch", "--single-branch",
          "https://github.com/alphagov/frontend.git", checkout.path.to_s
        )
      end
    end

    context "when the checkout already exists" do
      before { FileUtils.mkdir_p(checkout.path) }

      it "fetches and resets to the requested branch instead of cloning" do
        success = instance_double(Process::Status, success?: true)
        allow(Open3).to receive(:capture3).and_return(["", "", success])

        checkout.checkout!

        expect(Open3).to have_received(:capture3).with("git", "-C", checkout.path.to_s, "fetch", "origin", "my-branch")
        expect(Open3).to have_received(:capture3).with("git", "-C", checkout.path.to_s, "checkout", "-B", "my-branch", "origin/my-branch")
      end
    end

    it "raises GitError when the git command fails" do
      failure = instance_double(Process::Status, success?: false)
      allow(Open3).to receive(:capture3).and_return(["", "fatal: could not clone", failure])

      expect { checkout.checkout! }.to raise_error(described_class::GitError, /could not clone/)
    end
  end

  describe "#remove!" do
    it "removes the checkout directory" do
      FileUtils.mkdir_p(checkout.path)

      checkout.remove!

      expect(checkout.path).not_to exist
    end
  end
end

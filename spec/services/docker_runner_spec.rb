require "rails_helper"

RSpec.describe DockerRunner do
  let(:preview) { create(:preview, app_name: "frontend", branch: "my-branch", port: 20_123) }
  let(:runner) { described_class.new(preview) }
  let(:success) { instance_double(Process::Status, success?: true) }

  describe "#image_tag" do
    it "namespaces the image by app and includes the preview's slug" do
      expect(runner.image_tag).to eq("govuk-app-preview/frontend:#{preview.slug}")
    end
  end

  describe "#container_name" do
    it "is namespaced by the preview's slug" do
      expect(runner.container_name).to eq("govuk-app-preview-#{preview.slug}")
    end
  end

  describe "#build!" do
    it "builds the image from the checkout path" do
      allow(Open3).to receive(:capture3).and_return(["", "", success])

      runner.build!(Pathname.new("/tmp/some-checkout"))

      expect(Open3).to have_received(:capture3).with("docker", "build", "-t", runner.image_tag, "/tmp/some-checkout")
    end

    it "raises DockerError when the build fails" do
      failure = instance_double(Process::Status, success?: false)
      allow(Open3).to receive(:capture3).and_return(["", "no space left on device", failure])

      expect { runner.build!(Pathname.new("/tmp/some-checkout")) }
        .to raise_error(described_class::DockerError, /no space left/)
    end
  end

  describe "#start!" do
    it "runs the built image with the preview's port, a random secret key base, and the app's declared env" do
      allow(Open3).to receive(:capture3).and_return(["abc123\n", "", success])

      expect(runner.start!).to eq("abc123")
      expect(Open3).to have_received(:capture3) do |*args|
        expect(args[0..3]).to eq(["docker", "run", "-d", "--name"])
        expect(args[4]).to eq(runner.container_name)
        expect(args[5..6]).to eq(["-p", "20123:20123"])
        expect(args.last).to eq(runner.image_tag)

        env_section = args[7...-1]
        expect(env_section.each_slice(2).map(&:first).uniq).to eq(["-e"])
        env = env_section.each_slice(2).to_h { |_flag, kv| kv.split("=", 2) }
        expect(env["PORT"]).to eq("20123")
        expect(env["SECRET_KEY_BASE"]).to match(/\A[0-9a-f]{64}\z/)
        expect(env["PLEK_SERVICE_CONTENT_STORE_URI"]).to eq("https://www.gov.uk/api")
      end
    end

    it "generates a different secret key base for each container" do
      calls = []
      allow(Open3).to receive(:capture3) do |*args|
        calls << args
        ["abc123\n", "", success]
      end

      runner.start!
      runner.start!

      secret_key_bases = calls.map do |args|
        env = args[7...-1].each_slice(2).to_h { |_flag, kv| kv.split("=", 2) }
        env["SECRET_KEY_BASE"]
      end
      expect(secret_key_bases.uniq.size).to eq(2)
    end
  end

  describe "#stop!" do
    it "stops and removes the container if it exists and is running" do
      allow(Open3).to receive(:capture3)
        .with("docker", "inspect", "-f", "{{.State.Running}}", runner.container_name)
        .and_return(["true\n", "", success])
      allow(Open3).to receive(:capture3)
        .with("docker", "inspect", runner.container_name)
        .and_return(["", "", success])
      allow(Open3).to receive(:capture3).with("docker", "stop", runner.container_name).and_return(["", "", success])
      allow(Open3).to receive(:capture3).with("docker", "rm", runner.container_name).and_return(["", "", success])

      runner.stop!

      expect(Open3).to have_received(:capture3).with("docker", "stop", runner.container_name)
      expect(Open3).to have_received(:capture3).with("docker", "rm", runner.container_name)
    end

    it "does nothing destructive if the container doesn't exist" do
      not_found = instance_double(Process::Status, success?: false)
      allow(Open3).to receive(:capture3)
        .with("docker", "inspect", "-f", "{{.State.Running}}", runner.container_name)
        .and_return(["", "no such container", not_found])
      allow(Open3).to receive(:capture3)
        .with("docker", "inspect", runner.container_name)
        .and_return(["", "no such container", not_found])

      runner.stop!

      expect(Open3).not_to have_received(:capture3).with("docker", "stop", anything)
      expect(Open3).not_to have_received(:capture3).with("docker", "rm", anything)
    end
  end
end

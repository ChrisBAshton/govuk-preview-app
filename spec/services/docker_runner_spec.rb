require "rails_helper"

RSpec.describe DockerRunner do
  let(:preview) { create(:preview, app_name: "frontend", branch: "my-branch", port: 20_123) }
  let(:runner) { described_class.new(preview) }
  let(:success) { instance_double(Process::Status, success?: true) }

  def env_from(args)
    args[9...-1].each_slice(2).to_h { |_flag, kv| kv.split("=", 2) }
  end

  describe "#image_tag" do
    it "namespaces the image by app and includes the preview's slug" do
      expect(runner.image_tag).to eq("govuk-preview-app/frontend:#{preview.slug}")
    end
  end

  describe "#container_name" do
    it "is namespaced by the preview's slug" do
      expect(runner.container_name).to eq("govuk-preview-app-#{preview.slug}")
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
    it "removes any stale container first, then runs the built image with the preview's port and baseline env" do
      calls = []
      allow(Open3).to receive(:capture3) do |*args|
        calls << args
        ["abc123\n", "", success]
      end

      expect(runner.start!).to eq("abc123")

      expect(calls).to include(["docker", "rm", "-f", runner.container_name])

      run_args = calls.find { |args| args[0..2] == ["docker", "run", "-d"] }
      expect(run_args[3..4]).to eq(["--name", runner.container_name])
      expect(run_args[5..6]).to eq(["--network", "govuk-preview-app_default"])
      expect(run_args[7..8]).to eq(["-p", "20123:20123"])
      expect(run_args.last).to eq(runner.image_tag)

      env = env_from(run_args)
      expect(env["PORT"]).to eq("20123")
      expect(env["SECRET_KEY_BASE"]).to match(/\A[0-9a-f]{64}\z/)
      expect(env["RAILS_SERVE_STATIC_FILES"]).to eq("true")
      expect(env["GDS_SSO_STRATEGY"]).to eq("mock")
      expect(env["REDIS_URL"]).to eq("redis://redis:6379")
      expect(env["PLEK_SERVICE_CONTENT_STORE_URI"]).to eq("https://www.gov.uk/api")
    end

    it "omits the port publish flag when publish_port is false" do
      calls = []
      allow(Open3).to receive(:capture3) do |*args|
        calls << args
        ["abc123\n", "", success]
      end

      runner.start!(publish_port: false)

      run_args = calls.find { |args| args[0..2] == ["docker", "run", "-d"] }
      expect(run_args).not_to include("-p")
      expect(run_args[7..8]).to eq(["-e", "PORT=20123"])
    end

    it "merges extra_env on top of the baseline and manifest env" do
      calls = []
      allow(Open3).to receive(:capture3) do |*args|
        calls << args
        ["abc123\n", "", success]
      end

      runner.start!(extra_env: { "DATABASE_URL" => "postgresql://db/app_preview" })

      run_args = calls.find { |args| args[0..2] == ["docker", "run", "-d"] }
      expect(env_from(run_args)["DATABASE_URL"]).to eq("postgresql://db/app_preview")
    end

    it "generates a different secret key base for each container" do
      calls = []
      allow(Open3).to receive(:capture3) do |*args|
        calls << args
        ["abc123\n", "", success]
      end

      runner.start!
      runner.start!

      secret_key_bases = calls.select { |args| args[0..2] == ["docker", "run", "-d"] }.map { |args| env_from(args)["SECRET_KEY_BASE"] }
      expect(secret_key_bases.uniq.size).to eq(2)
    end
  end

  describe "#migrate!" do
    it "runs a one-off, auto-removed container preparing the database" do
      allow(Open3).to receive(:capture3).and_return(["", "", success])

      runner.migrate!(extra_env: { "DATABASE_URL" => "postgresql://db/app_preview" })

      expect(Open3).to have_received(:capture3) do |*args|
        expect(args[0..2]).to eq(["docker", "run", "--rm"])
        expect(args[3..4]).to eq(["--network", "govuk-preview-app_default"])
        expect(args.last(3)).to eq([runner.image_tag, "bin/rails", "db:prepare"])
      end
    end

    it "raises DockerError when the migrate run fails" do
      failure = instance_double(Process::Status, success?: false)
      allow(Open3).to receive(:capture3).and_return(["", "boom", failure])

      expect { runner.migrate! }.to raise_error(described_class::DockerError, /boom/)
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

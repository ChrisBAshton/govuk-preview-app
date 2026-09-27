require "rails_helper"

RSpec.describe DatabaseRunner do
  let(:preview) { create(:preview, app_name: "whitehall", branch: "my-branch") }
  let(:database) { GovukApps::Database.new(adapter: "mysql2", image: "mysql:8") }
  let(:runner) { described_class.new(preview, database) }
  let(:success) { instance_double(Process::Status, success?: true) }

  describe "#container_name" do
    it "is namespaced by the preview's slug, distinct from the app container" do
      expect(runner.container_name).to eq("govuk-preview-app-#{preview.slug}-db")
    end
  end

  describe "#database_url" do
    it "builds a mysql2 URL for a mysql2 adapter" do
      expect(runner.database_url).to eq("mysql2://root@#{runner.container_name}/app_preview")
    end

    it "builds a postgresql URL for a postgresql adapter" do
      pg_runner = described_class.new(preview, GovukApps::Database.new(adapter: "postgresql", image: "postgres:17"))

      expect(pg_runner.database_url).to eq("postgresql://postgres@#{pg_runner.container_name}/app_preview")
    end
  end

  describe "#start!" do
    it "removes any stale container, starts a fresh one, waits for readiness, and returns the database URL" do
      allow(Open3).to receive(:capture3).and_return(["", "", success])
      allow(Open3).to receive(:capture3)
        .with("docker", "exec", runner.container_name, "mysqladmin", "ping", "-h", "127.0.0.1", "--silent")
        .and_return(["", "", success])

      expect(runner.start!).to eq(runner.database_url)

      expect(Open3).to have_received(:capture3).with("docker", "rm", "-f", runner.container_name)
      expect(Open3).to have_received(:capture3).with(
        "docker", "run", "-d", "--name", runner.container_name, "--network", "govuk-preview-app_default",
        "-e", "MYSQL_ALLOW_EMPTY_PASSWORD=yes", "-e", "MYSQL_DATABASE=app_preview", "mysql:8"
      )
    end

    it "raises DatabaseError if the database never becomes ready" do
      stub_const("DatabaseRunner::READINESS_TIMEOUT", 0)
      not_ready = instance_double(Process::Status, success?: false)
      allow(Open3).to receive(:capture3).and_return(["", "", success])
      allow(Open3).to receive(:capture3)
        .with("docker", "exec", runner.container_name, "mysqladmin", "ping", "-h", "127.0.0.1", "--silent")
        .and_return(["", "", not_ready])

      expect { runner.start! }.to raise_error(described_class::DatabaseError, /did not become ready/)
    end

    it "checks postgresql readiness over TCP, not the default Unix socket" do
      pg_runner = described_class.new(preview, GovukApps::Database.new(adapter: "postgresql", image: "postgres:17"))
      allow(Open3).to receive(:capture3).and_return(["", "", success])
      allow(Open3).to receive(:capture3)
        .with("docker", "exec", pg_runner.container_name, "pg_isready", "-U", "postgres", "-h", "127.0.0.1")
        .and_return(["", "", success])

      expect(pg_runner.start!).to eq(pg_runner.database_url)
    end
  end

  describe "#stop!" do
    it "stops and removes the container" do
      allow(Open3).to receive(:capture3).and_return(["", "", success])

      runner.stop!

      expect(Open3).to have_received(:capture3).with("docker", "stop", runner.container_name)
      expect(Open3).to have_received(:capture3).with("docker", "rm", runner.container_name)
    end
  end

  describe "#exists?" do
    it "is true when docker inspect succeeds" do
      allow(Open3).to receive(:capture3).with("docker", "inspect", runner.container_name).and_return(["{}", "", success])

      expect(runner.exists?).to be(true)
    end

    it "is false when docker inspect fails" do
      failure = instance_double(Process::Status, success?: false)
      allow(Open3).to receive(:capture3).with("docker", "inspect", runner.container_name).and_return(["", "no such object", failure])

      expect(runner.exists?).to be(false)
    end
  end
end

require "rails_helper"

RSpec.describe KubernetesDatabaseRunner do
  let(:api) { kubernetes_api }
  let(:applied_stateful_sets) { [] }

  before do
    stub_request(:get, k8s_url(api.path("v1", "pods"))).with(query: hash_including({})).to_return(json_response({ items: [] }))
  end

  def runner_for(preview)
    database = GovukApps.find(preview.app_name).database
    described_class.new(preview, database, api: api).tap { |runner| allow(runner).to receive(:pause) }
  end

  def stub_applies(runner)
    stub_request(:patch, k8s_url(api.path("v1", "services", runner.container_name))).with(query: hash_including({})).to_return(json_response({}))
    stub_request(:patch, k8s_url(api.path("apps/v1", "statefulsets", runner.container_name))).with(query: hash_including({})).to_return do |req|
      applied_stateful_sets << JSON.parse(req.body)
      json_response({})
    end
    stub_request(:get, k8s_url(api.path("apps/v1", "statefulsets", runner.container_name)))
      .to_return(json_response({ status: {} }), json_response({ status: { readyReplicas: 1 } }))
  end

  def applied_stateful_set
    applied_stateful_sets.sole
  end

  it "keeps its name short enough for a StatefulSet's controller-revision-hash label" do
    preview = create(:preview, app_name: "content-store", branch: "a-really-long-branch-name-for-testing-truncation")

    expect(runner_for(preview).container_name.length).to be <= 52
  end

  context "with Postgres (publishing-api)" do
    let(:preview) { create(:preview, app_name: "publishing-api", branch: "my-branch") }
    let(:runner) { runner_for(preview) }

    it "applies a Service and StatefulSet, waits for readiness, and returns a DATABASE_URL using the Service name" do
      stub_applies(runner)

      expect(runner.start!).to eq("postgresql://postgres@#{runner.container_name}/app_preview")

      sts = applied_stateful_set
      pod = sts.dig("spec", "template", "spec")
      container = pod["containers"].first
      env = container["env"].to_h { |e| [e["name"], e["value"]] }

      expect(container["image"]).to eq("postgres:17")
      expect(pod["securityContext"]).to include("runAsUser" => 999, "fsGroup" => 999)
      expect(container["securityContext"]).to include("runAsNonRoot" => true, "allowPrivilegeEscalation" => false)
      expect(env).to include("POSTGRES_DB" => "app_preview", "PGDATA" => "/var/lib/preview-data/postgres")
      expect(container["args"]).to eq(%w[-c shared_buffers=16MB -c max_connections=40 -c work_mem=2MB])
      expect(container.dig("readinessProbe", "exec", "command")).to eq(["pg_isready", "-U", "postgres", "-h", "127.0.0.1"])
      expect(sts.dig("spec", "volumeClaimTemplates", 0, "spec", "resources", "requests", "storage")).to eq("1Gi")
      expect(sts.dig("spec", "persistentVolumeClaimRetentionPolicy", "whenDeleted")).to eq("Delete")
    end

    it "raises when the database never becomes ready" do
      stub_request(:patch, /k8s\.test/).to_return(json_response({}))
      stub_request(:get, /k8s\.test/).to_return(json_response({ status: {} }))
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with("PREVIEW_APP_DATABASE_TIMEOUT_SECONDS", 300).and_return("-1")

      expect { runner.start! }.to raise_error(described_class::DatabaseError, /did not become ready/)
    end

    it "deletes its StatefulSet, Service and volume on stop!" do
      stub_request(:delete, /k8s\.test/).to_return(json_response({}))

      runner.stop!

      expect(a_request(:delete, k8s_url(api.path("v1", "persistentvolumeclaims", "data-#{runner.container_name}-0")))
        .with(query: hash_including({}))).to have_been_made
    end
  end

  context "with MySQL (whitehall)" do
    let(:preview) { create(:preview, app_name: "whitehall", branch: "my-branch") }
    let(:runner) { runner_for(preview) }

    it "keeps MySQL's data directory below the volume root, and returns a mysql2 DATABASE_URL" do
      stub_applies(runner)

      # With root's password in the URL, so it overrides any password in the
      # app's own database.yml.
      expect(runner.start!).to eq("mysql2://root:root@#{runner.container_name}/app_preview")

      container = applied_stateful_set.dig("spec", "template", "spec", "containers", 0)
      expect(container["args"]).to include("--datadir=/var/lib/preview-data/mysql", "--performance-schema=OFF", "--innodb-buffer-pool-size=32M")
      expect(container.dig("readinessProbe", "exec", "command")).to include("mysqladmin", "ping")
    end
  end

  context "with MongoDB" do
    let(:preview) { create(:preview, app_name: "whitehall", branch: "mongo-branch") }
    let(:runner) do
      described_class.new(preview, GovukApps::Database.new(adapter: "mongodb", image: "mongo:7.0"), api:)
        .tap { |runner| allow(runner).to receive(:pause) }
    end

    it "hands the app a MONGODB_URI, and runs mongod with its data below the volume root and a small cache" do
      stub_applies(runner)

      expect(runner.start!).to eq("mongodb://#{runner.container_name}/app_preview")
      expect(runner.env_var).to eq("MONGODB_URI")

      container = applied_stateful_set.dig("spec", "template", "spec", "containers", 0)
      expect(container["command"].first(2)).to eq(["bash", "-c"])
      expect(container["command"][2]).to include("mkdir -p /var/lib/preview-data/mongo")
      expect(container["args"]).to eq(%w[mongod --dbpath /var/lib/preview-data/mongo --bind_ip_all --wiredTigerCacheSizeGB 0.25])
      expect(container["ports"].first["containerPort"]).to eq(27_017)
      expect(container.dig("readinessProbe", "exec", "command")).to include("mongosh")
    end
  end

  it "doesn't override MySQL's or Postgres's own entrypoint" do
    preview = create(:preview, app_name: "publishing-api", branch: "pg-branch")
    runner = runner_for(preview)
    stub_applies(runner)

    runner.start!

    expect(applied_stateful_set.dig("spec", "template", "spec", "containers", 0)).not_to have_key("command")
  end
end

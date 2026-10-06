require "rails_helper"

RSpec.describe KubernetesRunner do
  let(:preview) { create(:preview, app_name: "publishing-api", branch: "my-branch") }
  let(:image) { "ghcr.io/alphagov/govuk/publishing-api:abc123" }
  let(:api) { kubernetes_api }
  let(:runner) { described_class.new(preview, image: image, api: api) }

  let(:applied) { {} }

  before { allow(runner).to receive(:pause) }

  def apply_stub(api_version, resource, name, response = {})
    path = api.path(api_version, resource, name)
    stub_request(:patch, k8s_url(path)).with(query: hash_including({})).to_return do |req|
      applied[path] = JSON.parse(req.body)
      json_response(response)
    end
  end

  def applied_body(api_version, resource, name)
    applied.fetch(api.path(api_version, resource, name))
  end

  def env_hash(container)
    container["env"].to_h { |e| [e["name"], e["value"]] }
  end

  describe "#container_name and #service_host" do
    it "uses the same container name as Docker, and a fully-qualified Service name for HostRouter" do
      expect(runner.container_name).to eq("govuk-preview-app-#{preview.slug}")
      expect(runner.service_host).to eq("govuk-preview-app-#{preview.slug}.previews.svc.cluster.local")
    end
  end

  describe "#prepare!" do
    it "applies a ConfigMap holding the config overrides" do
      apply_stub("v1", "configmaps", "govuk-preview-app-#{preview.slug}-overrides")

      runner.prepare!

      body = applied_body("v1", "configmaps", "govuk-preview-app-#{preview.slug}-overrides")
      expect(body.dig("data", "zzz_preview_app_overrides.rb")).to eq(ConfigOverrides.content)
    end
  end

  describe "#start!" do
    let(:name) { runner.container_name }

    before do
      apply_stub("v1", "services", name)
      apply_stub("apps/v1", "deployments", name, { metadata: { uid: "deploy-uid" } })
    end

    it "applies a Service and a restricted-compliant Deployment, waits until it's available, and returns its uid" do
      stub_request(:get, k8s_url(api.path("apps/v1", "deployments", name)))
        .to_return(json_response({ status: {} }), json_response({ status: { availableReplicas: 1 } }))

      expect(runner.start!(extra_env: { "PLEK_SERVICE_CONTENT_STORE_URI" => "http://cs" })).to eq("deploy-uid")

      service = applied_body("v1", "services", name)
      expect(service.dig("spec", "ports", 0)).to include("port" => 80, "targetPort" => 3000)

      deployment = applied_body("apps/v1", "deployments", name)
      pod = deployment.dig("spec", "template", "spec")
      container = pod["containers"].first

      expect(container["image"]).to eq(image)
      expect(pod["automountServiceAccountToken"]).to be(false)
      expect(pod["enableServiceLinks"]).to be(false)
      expect(pod["securityContext"]).to include("runAsUser" => 1001, "seccompProfile" => { "type" => "RuntimeDefault" })
      expect(container["securityContext"]).to include(
        "allowPrivilegeEscalation" => false, "runAsNonRoot" => true, "capabilities" => { "drop" => %w[ALL] },
      )
      expect(container["volumeMounts"].first).to include(
        "mountPath" => "/app/config/initializers/zzz_preview_app_overrides.rb",
        "subPath" => "zzz_preview_app_overrides.rb",
      )
      expect(env_hash(container)).to include(
        "PORT" => "3000",
        "REDIS_URL" => "redis://redis:6379",
        "PLEK_SERVICE_CONTENT_STORE_URI" => "http://cs",
        "DISABLE_QUEUE_PUBLISHER" => "1",
      )
      expect(deployment.dig("metadata", "labels")).to include("govuk-preview-app/preview-id" => preview.id.to_s)
    end

    it "raises when the Deployment never becomes available" do
      stub_request(:get, k8s_url(api.path("apps/v1", "deployments", name))).to_return(json_response({ status: {} }))
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with("PREVIEW_APP_START_TIMEOUT_SECONDS", 600).and_return("-1")

      expect { runner.start! }.to raise_error(described_class::KubernetesError, /did not become ready/)
    end

    it "refuses to start without a resolved image" do
      runner = described_class.new(preview, api: api)

      expect { runner.start! }.to raise_error(described_class::KubernetesError, /No image resolved/)
    end
  end

  describe "#start_worker!" do
    it "applies a second Deployment running the manifest's worker_command, with no Service" do
      apply_stub("apps/v1", "deployments", runner.worker_container_name)

      runner.start_worker!

      deployment = applied_body("apps/v1", "deployments", runner.worker_container_name)
      container = deployment.dig("spec", "template", "spec", "containers", 0)
      expect(container["command"]).to eq(["bundle", "exec", "sidekiq", "-C", "./config/sidekiq.yml"])
      expect(container).not_to have_key("readinessProbe")
    end
  end

  describe "#migrate!" do
    let(:jobs_path) { api.path("batch/v1", "jobs") }

    it "runs db:create db:schema:load as a Job and waits for it to succeed" do
      job = nil
      stub_request(:post, k8s_url(jobs_path)).to_return do |req|
        job = JSON.parse(req.body)
        json_response({})
      end
      stub_request(:get, %r{\A#{Regexp.escape(k8s_url(jobs_path))}/})
        .to_return(json_response({ status: { active: 1 } }), json_response({ status: { succeeded: 1 } }))

      runner.migrate!(extra_env: { "DATABASE_URL" => "postgresql://postgres@db/app_preview" })

      container = job.dig("spec", "template", "spec", "containers", 0)
      expect(job.dig("spec", "backoffLimit")).to eq(0)
      expect(job.dig("spec", "template", "spec", "restartPolicy")).to eq("Never")
      expect(container["command"]).to eq(%w[bin/rails db:create db:schema:load])
      expect(env_hash(container)["DATABASE_URL"]).to eq("postgresql://postgres@db/app_preview")
      expect(job.dig("metadata", "name")).to start_with("govuk-preview-app-")
      expect(job.dig("metadata", "name").length).to be <= 63
    end

    it "raises with the relevant part of the Job's logs when it fails" do
      stub_request(:post, k8s_url(jobs_path)).to_return(json_response({}))
      stub_request(:get, %r{\A#{Regexp.escape(k8s_url(jobs_path))}/}).to_return(json_response({ status: { failed: 1 } }))
      stub_request(:get, k8s_url(api.path("v1", "pods"))).with(query: hash_including({}))
        .to_return(json_response({ items: [{ metadata: { name: "job-pod" } }] }))
      stub_request(:get, k8s_url(api.path("v1", "pods", "job-pod", "log"))).with(query: hash_including({}))
        .to_return(status: 200, body: "noise\nbin/rails aborted!\nActiveRecord::NoDatabaseError")

      expect { runner.migrate! }
        .to raise_error(described_class::KubernetesError, /\Abin\/rails db:create db:schema:load failed: bin\/rails aborted!/)
    end
  end

  describe "#stop!" do
    it "deletes the preview's Deployments, Service, ConfigMap and Jobs" do
      stub_request(:delete, /k8s\.test/).to_return(json_response({}))

      runner.stop!

      expect(a_request(:delete, k8s_url(api.path("apps/v1", "deployments", runner.container_name))).with(query: hash_including({}))).to have_been_made
      expect(a_request(:delete, k8s_url(api.path("apps/v1", "deployments", runner.worker_container_name))).with(query: hash_including({}))).to have_been_made
      expect(a_request(:delete, k8s_url(api.path("v1", "services", runner.container_name))).with(query: hash_including({}))).to have_been_made
      expect(a_request(:delete, k8s_url(api.path("batch/v1", "jobs")))
        .with(query: hash_including("labelSelector" => "govuk-preview-app/preview-id=#{preview.id}"))).to have_been_made
    end
  end

  describe "#exists?" do
    it "is false when the Deployment is gone" do
      stub_request(:get, k8s_url(api.path("apps/v1", "deployments", runner.container_name))).to_return(status: 404)

      expect(runner.exists?).to be(false)
    end
  end
end

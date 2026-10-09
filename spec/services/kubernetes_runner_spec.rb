require "rails_helper"

RSpec.describe KubernetesRunner do
  let(:preview) { create(:preview, app_name: "publishing-api", branch: "my-branch") }
  let(:image) { "ghcr.io/alphagov/govuk/publishing-api:abc123" }
  let(:api) { kubernetes_api }
  let(:runner) { described_class.new(preview, image: image, api: api) }

  let(:applied) { {} }

  before do
    allow(runner).to receive(:pause)
    # No pods stuck on an unusable image, unless a test says otherwise.
    stub_request(:get, k8s_url(api.path("v1", "pods"))).with(query: hash_including({})).to_return(json_response({ items: [] }))
  end

  def stub_pod_waiting(reason)
    stub_request(:get, k8s_url(api.path("v1", "pods")))
      .with(query: hash_including("labelSelector" => "app.kubernetes.io/instance=#{runner.container_name}"))
      .to_return(json_response({ items: [{ status: { containerStatuses: [{ image: image, state: { waiting: { reason: reason } } }] } }] }))
  end

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

  describe "#log_components" do
    it "offers only web for an app with no worker at all" do
      frontend_runner = described_class.new(create(:preview, app_name: "frontend", branch: "my-branch"), api: api)

      expect(frontend_runner.log_components).to eq(%w[web])
    end

    it "offers web and worker for an app whose worker runs as its own Deployment" do
      expect(runner.log_components).to eq(%w[web worker]) # preview is publishing-api
    end

    it "offers web and worker for an app whose worker runs inside the web pod instead" do
      whitehall_runner = described_class.new(create(:preview, app_name: "whitehall", branch: "my-branch"), api: api)

      expect(whitehall_runner.log_components).to eq(%w[web worker])
    end

    it "offers only web for a preview whose app has since been removed from the manifest" do
      preview.update_column(:app_name, "removed-app")

      expect(runner.log_components).to eq(%w[web])
    end
  end

  describe "#logs" do
    it "reads the web pod's own log, tailed to the default number of lines" do
      stub_request(:get, k8s_url(api.path("v1", "pods")))
        .with(query: hash_including("labelSelector" => "app.kubernetes.io/instance=#{runner.container_name}"))
        .to_return(json_response({ items: [{ metadata: { name: "web-pod" } }] }))
      stub_request(:get, k8s_url(api.path("v1", "pods", "web-pod", "log")))
        .with(query: { "tailLines" => "300" })
        .to_return(status: 200, body: "web log output")

      expect(runner.logs).to eq("web log output")
    end

    it "reads a separate worker Deployment's own pod, for an app whose worker isn't in the web pod" do
      stub_request(:get, k8s_url(api.path("v1", "pods")))
        .with(query: hash_including("labelSelector" => "app.kubernetes.io/instance=#{runner.worker_container_name}"))
        .to_return(json_response({ items: [{ metadata: { name: "worker-pod" } }] }))
      stub_request(:get, k8s_url(api.path("v1", "pods", "worker-pod", "log")))
        .with(query: { "tailLines" => "300" })
        .to_return(status: 200, body: "worker log output")

      expect(runner.logs(component: "worker")).to eq("worker log output")
    end

    it "reads the worker container within the web pod, for an app whose worker runs there instead" do
      whitehall_runner = described_class.new(create(:preview, app_name: "whitehall", branch: "my-branch"), api: api)
      stub_request(:get, k8s_url(api.path("v1", "pods")))
        .with(query: hash_including("labelSelector" => "app.kubernetes.io/instance=#{whitehall_runner.container_name}"))
        .to_return(json_response({ items: [{ metadata: { name: "whitehall-web-pod" } }] }))
      stub_request(:get, k8s_url(api.path("v1", "pods", "whitehall-web-pod", "log")))
        .with(query: { "tailLines" => "300", "container" => "worker" })
        .to_return(status: 200, body: "in-pod worker log output")

      expect(whitehall_runner.logs(component: "worker")).to eq("in-pod worker log output")
    end

    it "returns nil when no pod exists for it yet" do
      stub_request(:get, k8s_url(api.path("v1", "pods"))).with(query: hash_including({})).to_return(json_response({ items: [] }))

      expect(runner.logs).to be_nil
    end

    it "returns a readable message instead of raising, when the Kubernetes API errors" do
      stub_request(:get, k8s_url(api.path("v1", "pods"))).with(query: hash_including({}))
        .to_return(json_response({ items: [{ metadata: { name: "web-pod" } }] }))
      stub_request(:get, k8s_url(api.path("v1", "pods", "web-pod", "log"))).with(query: hash_including({})).to_return(status: 500, body: "boom")

      expect(runner.logs).to match(/\A\(couldn't read logs: GET .* failed \(500\)/)
    end
  end

  describe ".memory_for" do
    it "uses an app's measured memory settings from the manifest" do
      expect(described_class.memory_for(GovukApps.find("whitehall"))).to eq(request: "288Mi", limit: "768Mi")
    end

    it "falls back to a generous default for an app that hasn't been measured yet" do
      unmeasured = GovukApps::Definition.new(name: "new-app", memory: nil)

      expect(described_class.memory_for(unmeasured)).to eq(request: "384Mi", limit: "1536Mi")
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
        .to_return(json_response({ status: {} }), json_response(rolled_out_deployment))

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
        "GOVUK_ENVIRONMENT" => "integration",
        "WEB_CONCURRENCY" => "0",
        "RAILS_MAX_THREADS" => "3",
        "PORT" => "3000",
        # publishing-api is its own stack's top-level app, so database 0.
        "REDIS_URL" => "redis://govuk-preview-app-#{preview.slug}-redis:6379/0",
        "PLEK_SERVICE_CONTENT_STORE_URI" => "http://cs",
        "DISABLE_QUEUE_PUBLISHER" => "1",
      )
      expect(deployment.dig("metadata", "labels")).to include(
        "govuk-preview-app/preview-id" => preview.id.to_s,
        "govuk-preview-app/root-id" => preview.id.to_s,
      )
    end

    it "keeps waiting while the old pod is still serving, until the new version has fully rolled out" do
      old_pod_still_up = { metadata: { generation: 3 },
                           spec: { replicas: 1 },
                           status: { observedGeneration: 3, replicas: 2, updatedReplicas: 1, availableReplicas: 1 } }
      deployment = stub_request(:get, k8s_url(api.path("apps/v1", "deployments", name)))
        .to_return(json_response(old_pod_still_up), json_response(rolled_out_deployment))

      runner.start!

      expect(deployment).to have_been_requested.twice
    end

    it "raises when the Deployment never becomes available" do
      stub_request(:get, k8s_url(api.path("apps/v1", "deployments", name))).to_return(json_response({ status: {} }))
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with("PREVIEW_APP_START_TIMEOUT_SECONDS", 600).and_return("-1")

      expect { runner.start! }.to raise_error(described_class::KubernetesError, /did not become ready/)
    end

    it "pulls a registry image only if it isn't already on the node" do
      stub_request(:get, k8s_url(api.path("apps/v1", "deployments", name))).to_return(json_response(rolled_out_deployment))

      runner.start!

      expect(applied_body("apps/v1", "deployments", name).dig("spec", "template", "spec", "containers", 0, "imagePullPolicy")).to eq("IfNotPresent")
    end

    context "with a locally-built image" do
      let(:image) { "govuk-preview-local/publishing-api:my-branch-abc1234" }

      it "never tries to pull it" do
        stub_request(:get, k8s_url(api.path("apps/v1", "deployments", name))).to_return(json_response(rolled_out_deployment))

        runner.start!

        expect(applied_body("apps/v1", "deployments", name).dig("spec", "template", "spec", "containers", 0, "imagePullPolicy")).to eq("Never")
      end

      it "fails straight away, with a hint, when the image hasn't been loaded into the cluster" do
        stub_request(:get, k8s_url(api.path("apps/v1", "deployments", name))).to_return(json_response({ status: {} }))
        stub_pod_waiting("ErrImageNeverPull")

        expect { runner.start! }.to raise_error(
          described_class::KubernetesError,
          "Can't use image #{image} (ErrImageNeverPull) - has it been built and loaded with bin/preview-build?",
        )
      end
    end

    it "keeps waiting through a registry pull that may yet succeed" do
      stub_request(:get, k8s_url(api.path("apps/v1", "deployments", name)))
        .to_return(json_response({ status: {} }), json_response(rolled_out_deployment))
      stub_pod_waiting("ImagePullBackOff")

      expect(runner.start!).to eq("deploy-uid")
    end

    it "refuses to start without a resolved image" do
      runner = described_class.new(preview, api: api)

      expect { runner.start! }.to raise_error(described_class::KubernetesError, /No image resolved/)
    end
  end

  describe "#start_worker!" do
    it "applies a second Deployment running the manifest's worker_command at a preview-sized concurrency, with no Service" do
      apply_stub("apps/v1", "deployments", runner.worker_container_name)

      runner.start_worker!

      deployment = applied_body("apps/v1", "deployments", runner.worker_container_name)
      container = deployment.dig("spec", "template", "spec", "containers", 0)
      expect(container["command"]).to eq(["bundle", "exec", "sidekiq", "-C", "./config/sidekiq.yml", "-c", "2"])
      expect(container).not_to have_key("readinessProbe")
      expect(env_hash(container)).not_to include("WEB_CONCURRENCY", "RAILS_MAX_THREADS")
    end
  end

  describe "an app with shared_volumes" do
    let(:preview) { create(:preview, app_name: "asset-manager", branch: "my-branch") }
    let(:image) { "ghcr.io/alphagov/govuk/asset-manager:abc123" }
    let(:name) { runner.container_name }
    let(:claim) { "govuk-preview-app-#{preview.slug}-fake-s3" }

    it "keeps each persistent volume on a claim of its own" do
      apply_stub("v1", "persistentvolumeclaims", claim)
      apply_stub("v1", "configmaps", "govuk-preview-app-#{preview.slug}-overrides")

      runner.prepare!

      expect(applied_body("v1", "persistentvolumeclaims", claim).dig("spec", "accessModes")).to eq(%w[ReadWriteOnce])
    end

    it "runs its worker in the web pod, with the volumes mounted in both" do
      apply_stub("v1", "services", name)
      apply_stub("apps/v1", "deployments", name)
      stub_request(:get, k8s_url(api.path("apps/v1", "deployments", name))).to_return(json_response(rolled_out_deployment))

      runner.start!

      pod = applied_body("apps/v1", "deployments", name).dig("spec", "template", "spec")
      expect(pod["containers"].map { |c| c["name"] }).to eq(%w[app worker])
      expect(pod["containers"].last["command"]).to eq(["bundle", "exec", "sidekiq", "-C", "./config/sidekiq.yml", "-c", "2"])
      pod["containers"].each do |container|
        expect(container["volumeMounts"].map { |m| m["mountPath"] }).to include("/uploads", "/app/fake-s3")
      end
      expect(pod["volumes"]).to include(
        { "name" => "shared-uploads", "emptyDir" => {} },
        { "name" => "shared-fake-s3", "persistentVolumeClaim" => { "claimName" => claim } },
      )
      expect(pod["securityContext"]).to include("fsGroup" => 1001)
    end

    it "has no worker Deployment of its own, and removes one left from before" do
      delete = stub_request(:delete, k8s_url(api.path("apps/v1", "deployments", runner.worker_container_name)))
        .with(query: hash_including({})).to_return(json_response({}))
      scale = stub_request(:patch, %r{/deployments/}).to_return(json_response({}))

      runner.start_worker!
      runner.scale!(0)

      expect(delete).to have_been_made
      expect(scale).to have_been_requested.once
    end

    it "deletes its claims along with everything else" do
      stub_request(:delete, /k8s\.test/).to_return(json_response({}))

      runner.stop!

      expect(a_request(:delete, k8s_url(api.path("v1", "persistentvolumeclaims", claim))).with(query: hash_including({}))).to have_been_made
    end

    it "sets its self_url_env to its own public URL" do
      apply_stub("v1", "services", name)
      apply_stub("apps/v1", "deployments", name)
      stub_request(:get, k8s_url(api.path("apps/v1", "deployments", name))).to_return(json_response(rolled_out_deployment))

      runner.start!

      container = applied_body("apps/v1", "deployments", name).dig("spec", "template", "spec", "containers", 0)
      expect(env_hash(container)).to include("FAKE_S3_HOST" => preview.url, "PLEK_SERVICE_DRAFT_ASSETS_URI" => preview.url)
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
      # Re-runnable, despite RAILS_ENV=production.
      expect(env_hash(container)["DISABLE_DATABASE_ENVIRONMENT_CHECK"]).to eq("1")
      expect(env_hash(container)).not_to include("WEB_CONCURRENCY")
      expect(job.dig("metadata", "name")).to start_with("govuk-preview-app-")
      expect(job.dig("metadata", "name").length).to be <= 63
    end

    it "creates indexes instead for a Mongoid app, which has no schema to load" do
      job = nil
      stub_request(:post, k8s_url(jobs_path)).to_return do |req|
        job = JSON.parse(req.body)
        json_response({})
      end
      stub_request(:get, %r{\A#{Regexp.escape(k8s_url(jobs_path))}/}).to_return(json_response({ status: { succeeded: 1 } }))

      runner.migrate!(adapter: "mongodb")

      expect(job.dig("spec", "template", "spec", "containers", 0, "command")).to eq(%w[bin/rails db:mongoid:create_indexes])
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

  describe "#scale!" do
    it "scales the app's Deployment and its worker's" do
      stub = stub_request(:patch, %r{/deployments/}).to_return(json_response({}))

      runner.scale!(0)

      expect(stub).to have_been_requested.twice
      expect(a_request(:patch, k8s_url(api.path("apps/v1", "deployments", runner.worker_container_name)))
        .with(body: { spec: { replicas: 0 } }.to_json, headers: { "Content-Type" => "application/merge-patch+json" })).to have_been_made
    end
  end

  describe ".report_scheduling" do
    let(:unschedulable_pod) do
      { status: { conditions: [{ type: "PodScheduled", status: "False", reason: "Unschedulable", message: "0/1 nodes are available: 1 Insufficient memory." }] } }.deep_stringify_keys
    end

    it "says on the preview when a pod is waiting for room in the cluster, and clears it once it isn't" do
      described_class.report_scheduling(preview, [unschedulable_pod])
      expect(preview.reload.status_message).to eq("Waiting for cluster capacity: 0/1 nodes are available: 1 Insufficient memory.")

      described_class.report_scheduling(preview, [])
      expect(preview.reload.status_message).to be_nil
    end

    it "leaves any other status message alone" do
      preview.update!(status_message: "something else")

      described_class.report_scheduling(preview, [])

      expect(preview.reload.status_message).to eq("something else")
    end
  end

  describe "a Job that never ran" do
    it "fails with Kubernetes' own reason instead of missing logs" do
      jobs_path = api.path("batch/v1", "jobs")
      stub_request(:post, k8s_url(jobs_path)).to_return(json_response({}))
      stub_request(:get, %r{\A#{Regexp.escape(k8s_url(jobs_path))}/}).to_return(json_response({
        status: { conditions: [{ type: "Failed", status: "True", reason: "DeadlineExceeded", message: "Job was active longer than specified deadline" }] },
      }))

      expect { runner.migrate! }.to raise_error(described_class::KubernetesError, /failed: Job was active longer than specified deadline/)
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

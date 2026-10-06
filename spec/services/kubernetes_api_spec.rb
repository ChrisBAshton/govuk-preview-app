require "rails_helper"

RSpec.describe KubernetesApi do
  let(:api) { kubernetes_api }

  describe "#path" do
    it "builds core API paths under the previews namespace" do
      expect(api.path("v1", "services", "my-svc")).to eq("/api/v1/namespaces/previews/services/my-svc")
    end

    it "builds grouped API paths, with an optional subresource" do
      expect(api.path("v1", "pods", "my-pod", "log")).to eq("/api/v1/namespaces/previews/pods/my-pod/log")
      expect(api.path("apps/v1", "deployments")).to eq("/apis/apps/v1/namespaces/previews/deployments")
    end

    it "uses the namespace from PREVIEW_APP_KUBERNETES_NAMESPACE" do
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with("PREVIEW_APP_KUBERNETES_NAMESPACE", "previews").and_return("elsewhere")

      expect(api.path("v1", "services")).to eq("/api/v1/namespaces/elsewhere/services")
    end
  end

  describe "#apply" do
    it "server-side applies the object with the service account token, forcing ownership" do
      path = api.path("v1", "configmaps", "cm")
      stub = stub_request(:patch, k8s_url(path))
        .with(
          query: { fieldManager: "govuk-preview-app", force: "true" },
          headers: { "Authorization" => "Bearer test-token", "Content-Type" => "application/apply-patch+yaml" },
          body: { kind: "ConfigMap" }.to_json,
        )
        .to_return(json_response({ metadata: { uid: "abc" } }))

      expect(api.apply(path, { kind: "ConfigMap" })).to eq({ "metadata" => { "uid" => "abc" } })
      expect(stub).to have_been_requested
    end
  end

  describe "#get" do
    it "raises NotFound for a 404" do
      path = api.path("apps/v1", "deployments", "missing")
      stub_request(:get, k8s_url(path)).to_return(status: 404, body: "{}")

      expect { api.get(path) }.to raise_error(described_class::NotFound)
    end

    it "raises Error with the API's own message for any other failure" do
      path = api.path("apps/v1", "deployments", "forbidden")
      stub_request(:get, k8s_url(path)).to_return(json_response({ message: "deployments is forbidden" }, status: 403))

      expect { api.get(path) }.to raise_error(described_class::Error, /403.*deployments is forbidden/)
    end
  end

  describe "#delete" do
    it "deletes with background propagation" do
      path = api.path("apps/v1", "deployments", "d")
      stub = stub_request(:delete, k8s_url(path)).with(query: { propagationPolicy: "Background" }).to_return(json_response({}))

      api.delete(path)

      expect(stub).to have_been_requested
    end

    it "treats an already-missing object as success" do
      path = api.path("apps/v1", "deployments", "d")
      stub_request(:delete, k8s_url(path)).with(query: hash_including({})).to_return(status: 404)

      expect { api.delete(path) }.not_to raise_error
    end
  end
end

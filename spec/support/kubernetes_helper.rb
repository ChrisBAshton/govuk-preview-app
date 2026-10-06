module KubernetesHelper
  K8S_BASE = "https://k8s.test".freeze

  def kubernetes_api
    token = Tempfile.new("k8s-token")
    token.write("test-token")
    token.flush
    KubernetesApi.new(host: "k8s.test", port: "443", token_path: token.path, ca_path: "/nonexistent")
  end

  def k8s_url(path)
    "#{K8S_BASE}#{path}"
  end

  def json_response(body, status: 200)
    { status: status, body: body.to_json, headers: { "Content-Type" => "application/json" } }
  end
end

RSpec.configure { |config| config.include KubernetesHelper }

module KubernetesHelper
  K8S_BASE = "https://k8s.test".freeze

  def kubernetes_api
    KubernetesApi.new(host: "k8s.test", port: "443", token_path: kubernetes_token_file.path, ca_path: "/nonexistent")
  end

  # Held for the whole example: an unreferenced Tempfile deletes its file
  # whenever it's garbage-collected, which can happen mid-example.
  def kubernetes_token_file
    @kubernetes_token_file ||= Tempfile.new("k8s-token").tap do |file|
      file.write("test-token")
      file.flush
    end
  end

  def k8s_url(path)
    "#{K8S_BASE}#{path}"
  end

  def json_response(body, status: 200)
    { status: status, body: body.to_json, headers: { "Content-Type" => "application/json" } }
  end
end

RSpec.configure { |config| config.include KubernetesHelper }

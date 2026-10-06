require "json"
require "net/http"

# A deliberately tiny client for the handful of Kubernetes API calls
# KubernetesRunner/KubernetesDatabaseRunner make - all namespaced to the
# single namespace Preview App's service account is allowed to touch (see
# govuk-helm-charts' charts/govuk-previews Role), never cluster-wide.
#
# Authenticates with the pod's own mounted service account token, the
# standard in-cluster mechanism - no kubeconfig, no extra credentials.
#
# Writes use server-side apply (PATCH with application/apply-patch+yaml),
# which creates-or-updates in one idempotent call - so a Sidekiq retry
# after a partial failure just converges, instead of colliding with an
# object a previous attempt already created.
class KubernetesApi
  class Error < StandardError; end
  class NotFound < Error; end

  SERVICE_ACCOUNT_DIR = Pathname.new("/var/run/secrets/kubernetes.io/serviceaccount")
  FIELD_MANAGER = "govuk-preview-app".freeze

  def self.namespace
    ENV.fetch("PREVIEW_APP_KUBERNETES_NAMESPACE", "previews")
  end

  def initialize(
    host: ENV.fetch("KUBERNETES_SERVICE_HOST", "kubernetes.default.svc"),
    port: ENV.fetch("KUBERNETES_SERVICE_PORT", "443"),
    token_path: SERVICE_ACCOUNT_DIR.join("token"),
    ca_path: SERVICE_ACCOUNT_DIR.join("ca.crt")
  )
    @base_uri = URI("https://#{host}:#{port}")
    @token_path = token_path
    @ca_path = ca_path
  end

  # e.g. path("apps/v1", "deployments", "my-deployment")
  def path(api_version, resource, name = nil, subresource = nil)
    prefix = api_version == "v1" ? "/api/v1" : "/apis/#{api_version}"
    [prefix, "namespaces", self.class.namespace, resource, name, subresource].compact.join("/")
  end

  def get(path, params = {})
    request(Net::HTTP::Get, path, params: params)
  end

  def get_text(path, params = {})
    request(Net::HTTP::Get, path, params: params, parse: false)
  end

  def apply(path, body)
    request(
      Net::HTTP::Patch, path,
      params: { fieldManager: FIELD_MANAGER, force: true },
      body: body.to_json,
      content_type: "application/apply-patch+yaml"
    )
  end

  def create(path, body)
    request(Net::HTTP::Post, path, body: body.to_json, content_type: "application/json")
  end

  def merge_patch(path, body)
    request(Net::HTTP::Patch, path, body: body.to_json, content_type: "application/merge-patch+json")
  end

  # Background propagation: the object itself goes away straight away and
  # its dependents (a Deployment's ReplicaSets/Pods, a Job's Pods) are
  # garbage-collected afterwards - the same "fire and forget" shape as
  # `docker rm -f`. A missing object is already the desired end state.
  def delete(path, params = {})
    request(Net::HTTP::Delete, path, params: params.merge(propagationPolicy: "Background"))
  rescue NotFound
    nil
  end

  def exists?(path)
    get(path)
    true
  rescue NotFound
    false
  end

private

  attr_reader :base_uri, :token_path, :ca_path

  def request(klass, path, params: {}, body: nil, content_type: nil, parse: true)
    uri = base_uri.dup
    uri.path = path
    uri.query = URI.encode_www_form(params) if params.any?

    req = klass.new(uri)
    req["Authorization"] = "Bearer #{File.read(token_path).strip}"
    req["Accept"] = "application/json"
    if body
      req["Content-Type"] = content_type
      req.body = body
    end

    response = http.request(req)
    raise NotFound, "#{klass::METHOD} #{path}: not found" if response.code == "404"
    unless response.is_a?(Net::HTTPSuccess)
      raise Error, "#{klass::METHOD} #{path} failed (#{response.code}): #{error_message(response)}"
    end

    return response.body.to_s unless parse

    response.body.present? ? JSON.parse(response.body) : {}
  end

  def http
    Net::HTTP.new(base_uri.host, base_uri.port).tap do |http|
      http.use_ssl = true
      http.ca_file = ca_path.to_s if File.exist?(ca_path)
      http.open_timeout = 5
      http.read_timeout = 30
    end
  end

  def error_message(response)
    JSON.parse(response.body.to_s).fetch("message", response.body.to_s)
  rescue JSON::ParserError
    response.body.to_s
  end
end

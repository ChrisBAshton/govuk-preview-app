# Each preview stack's own Redis - owned by its top-level preview, like the
# rest of the stack, and never shared with another stack.
#
# On GOV.UK every app has a Redis of its own. Sharing one between previews
# isn't just untidy: apps share Sidekiq queue names (e.g. `default`), so
# one app's worker would pick up - and fail on - another app's jobs, and
# two stacks' Publishing API workers would each process the other's
# publishing jobs against the wrong database and Content Stores. So each
# app in a stack also gets its own numbered Redis database, in the order
# its app appears in the stack (see GovukApps.dependency_tree) - stable
# whether the stack is core or full.
class StackRedis
  class TooManyAppsError < StandardError; end

  # Redis' default number of databases.
  MAX_DATABASES = 16
  PORT = 6379

  def self.memory
    {
      request: ENV.fetch("PREVIEW_APP_REDIS_MEMORY_REQUEST", "32Mi"),
      limit: ENV.fetch("PREVIEW_APP_REDIS_MEMORY_LIMIT", "128Mi"),
    }
  end

  # The REDIS_URL for a preview's pods - its stack's Redis, and its app's
  # own database within it.
  def self.url_for(preview)
    root = preview.root
    apps = [root.app_name, *GovukApps.dependency_tree(root.app_name)].uniq
    database = apps.index(preview.app_name)
    raise TooManyAppsError, "#{root.app_name}'s stack has more apps than Redis has databases" if database >= MAX_DATABASES

    "redis://#{new(root).name}:#{PORT}/#{database}"
  end

  attr_reader :root

  def initialize(root, api: KubernetesApi.new)
    @root = root
    @api = api
  end

  def name
    ContainerName.for(root.slug, suffix: "-redis")
  end

  # Idempotent, like everything else applied with server-side apply.
  def start!
    api.apply(api.path("v1", "services", name), service)
    api.apply(api.path("apps/v1", "deployments", name), deployment)
  end

  def scale!(replicas)
    api.merge_patch(api.path("apps/v1", "deployments", name), { spec: { replicas: replicas } })
  rescue KubernetesApi::NotFound
    nil # e.g. a stack built before stacks had their own Redis
  end

  def stop!
    api.delete(api.path("apps/v1", "deployments", name))
    api.delete(api.path("v1", "services", name))
  end

private

  attr_reader :api

  def labels
    KubernetesRunner.labels_for(root, "redis")
  end

  def service
    {
      apiVersion: "v1",
      kind: "Service",
      metadata: { name: name, labels: labels },
      spec: {
        selector: { "app.kubernetes.io/instance" => name },
        ports: [{ name: "redis", port: PORT, targetPort: PORT }],
      },
    }
  end

  # No volume: it only ever holds queued jobs and caches, and losing those
  # when a stack is put to sleep is harmless.
  def deployment
    {
      apiVersion: "apps/v1",
      kind: "Deployment",
      metadata: { name: name, labels: labels },
      spec: {
        replicas: 1,
        selector: { matchLabels: { "app.kubernetes.io/instance" => name } },
        template: {
          metadata: { labels: labels.merge("app.kubernetes.io/instance" => name) },
          spec: {
            automountServiceAccountToken: false,
            enableServiceLinks: false,
            securityContext: {
              runAsUser: 999,
              runAsGroup: 999,
              seccompProfile: { type: "RuntimeDefault" },
            },
            containers: [
              {
                name: "redis",
                image: "redis:8.6",
                args: ["--save", "", "--appendonly", "no", "--databases", MAX_DATABASES.to_s],
                ports: [{ name: "redis", containerPort: PORT }],
                resources: {
                  requests: { cpu: "10m", memory: self.class.memory[:request] },
                  limits: { memory: self.class.memory[:limit] },
                },
                securityContext: KubernetesRunner.container_security_context,
              },
            ],
          },
        },
      },
    }
  end
end

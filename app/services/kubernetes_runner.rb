# Runs a preview's app as a Deployment + Service in the previews namespace,
# its optional worker as a second Deployment from the same image, and its
# one-off rake tasks (migrate/seed/setup_tasks) as Jobs.
#
# An app with `shared_volumes` (see config/govuk_apps.yml) runs its worker as
# a second container in the web pod instead, so the two can share files -
# e.g. Whitehall's web process saves an upload that its worker then sends to
# Asset Manager.
#
# There's no build step: the image was already built and pushed by the
# app's own GitHub Actions workflow, and found by ImageResolver. Nothing
# here needs privileges - every pod runs as the image's own non-root user
# under the namespace's `restricted` Pod Security standard.
#
# Every object is named by ContainerName, so other previews in the same
# namespace reach it at plain `http://<name>` (see
# PreviewBuilder#build_dependencies!) - a bare Service name resolves within
# its own namespace, and every Service listens on port 80.
class KubernetesRunner
  class KubernetesError < KubernetesApi::Error; end

  # Every pod has its own IP, so every app can listen on the same port -
  # its Service maps port 80 onto it.
  APP_PORT = 3000

  # GOV.UK's base images all set APP_HOME=/app - the overrides file has to
  # land in the app's own config/initializers to take effect.
  OVERRIDES_PATH = "/app/config/initializers/#{ConfigOverrides::FILENAME}".freeze
  OVERRIDES_KEY = ConfigOverrides::FILENAME

  # GOV.UK images set `USER app` by name, which Kubernetes can't verify as
  # non-root on its own - the numeric uid has to be explicit (the same one
  # generic-govuk-app uses for every real app).
  APP_UID = 1001

  POLL_INTERVAL = 5

  # Kubernetes never gives up on a pod whose image it can't use - it just
  # waits - so without checking for these, a typo'd or not-yet-loaded
  # local image would only surface as a timeout many minutes later. These
  # reasons never fix themselves; a registry pull that's merely slow or
  # flaky (ErrImagePull, ImagePullBackOff) is still left to retry until
  # the timeout.
  UNRECOVERABLE_IMAGE_REASONS = %w[ErrImageNeverPull InvalidImageName].freeze

  CAPACITY_MESSAGE_PREFIX = "Waiting for cluster capacity: ".freeze

  # Apps hardcode their Sidekiq concurrency in config/sidekiq.yml (e.g.
  # Publishing API's 12) - far more threads, and so database connections
  # and memory, than a preview needs. Sidekiq's command-line options take
  # precedence over its config file, so this needs no change in the app.
  WORKER_CONCURRENCY = 2

  attr_reader :preview, :image

  def self.api_reachable?
    api = KubernetesApi.new
    api.get(api.path("v1", "services"), limit: 1)
    true
  rescue KubernetesApi::Error, SystemCallError, IOError, OpenSSL::SSL::SSLError, Net::OpenTimeout
    false
  end

  # Shared with KubernetesDatabaseRunner - the namespace enforces the
  # `restricted` Pod Security standard, which rejects any pod without these.
  def self.container_security_context
    {
      allowPrivilegeEscalation: false,
      runAsNonRoot: true,
      capabilities: { drop: %w[ALL] },
    }
  end

  # What each of an app's pods (web, worker and tasks) asks for: its
  # manifest entry's `memory`, measured with bin/preview-usage - or, for an
  # app without one, a generous default. Also what PreviewCapacity adds up
  # to work out how much room a whole preview stack needs.
  def self.memory_for(app)
    {
      request: app.memory&.fetch("request", nil) || ENV.fetch("PREVIEW_APP_POD_MEMORY_REQUEST", "384Mi"),
      limit: app.memory&.fetch("limit", nil) || ENV.fetch("PREVIEW_APP_POD_MEMORY_LIMIT", "1536Mi"),
    }
  end

  # While a pod can't be scheduled (e.g. "0/1 nodes are available: 1
  # Insufficient memory"), say so on the preview itself - otherwise it just
  # sits at "starting" with no clue why. Cleared again once it's scheduled.
  # On integration this is usually brief (the cluster autoscaler adds a
  # node); locally it means the kind node is full.
  def self.report_scheduling(preview, pods)
    unschedulable = pods.flat_map { |pod| pod.dig("status", "conditions").to_a }
      .find { |c| c["type"] == "PodScheduled" && c["status"] == "False" && c["reason"] == "Unschedulable" }

    if unschedulable
      preview.update_column(:status_message, "#{CAPACITY_MESSAGE_PREFIX}#{unschedulable['message']}".truncate(255))
    elsif preview.status_message.to_s.start_with?(CAPACITY_MESSAGE_PREFIX)
      preview.update_column(:status_message, nil)
    end
  end

  def self.labels_for(preview, component)
    {
      "app.kubernetes.io/managed-by" => "govuk-preview-app",
      "govuk-preview-app/preview-id" => preview.id.to_s,
      # Which stack it's part of - see bin/preview-usage.
      "govuk-preview-app/root-id" => preview.root.id.to_s,
      "govuk-preview-app/app" => preview.app_name,
      "govuk-preview-app/component" => component,
    }
  end

  def initialize(preview, image: nil, api: KubernetesApi.new)
    @preview = preview
    @image = image
    @api = api
  end

  def container_name
    ContainerName.for(preview.slug)
  end

  def worker_container_name
    ContainerName.for(preview.slug, suffix: "-worker")
  end

  # HostRouter runs in Preview App's own pod, in a different namespace from
  # the previews themselves, so it needs the fully-qualified Service name.
  def service_host
    "#{container_name}.#{KubernetesApi.namespace}.svc.cluster.local"
  end

  DEFAULT_LOG_LINES = 300

  # "web" always; "worker" too, whenever the app runs one at all - whether
  # as its own Deployment, or as a second container inside the web pod
  # (see #worker_in_web_pod?); #logs below reads the right one either way.
  # Guarded against an app since removed from the manifest (see
  # Preview#app_known?), which #worker_in_web_pod? itself isn't safe to
  # call for.
  def log_components
    return %w[web] unless app

    app.worker_command.present? ? %w[web worker] : %w[web]
  end

  # The most recent lines of a component's own container's log - nil if no
  # pod exists for it yet (still starting, asleep, or never built).
  def logs(component: "web", tail_lines: DEFAULT_LOG_LINES)
    separate_worker_pod = component == "worker" && !worker_in_web_pod?
    deployment = separate_worker_pod ? worker_container_name : container_name
    pod = api.get(api.path("v1", "pods"), labelSelector: "app.kubernetes.io/instance=#{deployment}").fetch("items", []).first
    return nil if pod.nil?

    # Every pod_spec container is named explicitly ("app" or "worker",
    # see #container) - naming it here is only ever strictly required for
    # a worker-in-web-pod app's web pod, which has both and leaves
    # Kubernetes nothing to default to, but it's never wrong to also name
    # it for a pod that happens to only have the one.
    container = component == "worker" && !separate_worker_pod ? "worker" : "app"
    api.get_text(api.path("v1", "pods", pod.dig("metadata", "name"), "log"), tailLines: tail_lines, container: container)
  rescue KubernetesApi::Error => e
    "(couldn't read logs: #{e.message})"
  end

  # The fixes ConfigOverrides used to write into a checkout before
  # `docker build` - mounted into every pod instead, since the image is
  # prebuilt and can't be modified.
  def prepare!
    persistent_volumes.each_key do |volume|
      api.apply(api.path("v1", "persistentvolumeclaims", claim_name(volume)), claim(volume))
    end

    api.apply(
      api.path("v1", "configmaps", overrides_name),
      {
        apiVersion: "v1",
        kind: "ConfigMap",
        metadata: { name: overrides_name, labels: labels("config") },
        data: { OVERRIDES_KEY => ConfigOverrides.content },
      },
    )
  end

  # Every preview gets a ClusterIP Service, reachable only from inside the
  # cluster - whether it's publicly routable is decided entirely by
  # HostRouter.
  def start!(extra_env: {})
    require_image!

    api.apply(api.path("v1", "services", container_name), service)
    deployment = api.apply(
      api.path("apps/v1", "deployments", container_name),
      deployment(container_name, component: "web", env: extra_env, web: true),
    )

    # Unlike `docker run -d`, a Deployment isn't serving anything until its
    # image has been pulled and the app has booted - and with no build step
    # to hide behind, a parent preview's migrations/setup tasks (e.g.
    # Whitehall's taxonomy tasks, which call Publishing API) would otherwise
    # start racing a dependency that isn't up yet.
    wait_until_available!(container_name)

    deployment.dig("metadata", "uid")
  end

  def start_worker!(extra_env: {})
    require_image!

    # Runs in the web pod instead (see #start!) - and a preview started
    # before the app shared volumes may still have a Deployment of its own.
    if worker_in_web_pod?
      api.delete(api.path("apps/v1", "deployments", worker_container_name))
      return
    end

    api.apply(
      api.path("apps/v1", "deployments", worker_container_name),
      deployment(
        worker_container_name,
        component: "worker",
        env: extra_env,
        command: worker_command,
      ),
    )
  end

  # Deliberately db:create db:schema:load, not db:prepare: db:prepare also
  # seeds the database itself the first time it creates one (see
  # ActiveRecord::Tasks::DatabaseTasks#prepare_all), which would double-seed
  # alongside our own explicit #seed! call. MongoDB has no schema - its
  # databases appear on first write - so Mongoid apps just get their
  # indexes.
  #
  # DISABLE_DATABASE_ENVIRONMENT_CHECK: previews run with
  # RAILS_ENV=production, and once a schema has been loaded Rails refuses to
  # load it again into a "production" database. But a preview's build has
  # to be re-runnable from any point (e.g. retrying one that failed while
  # seeding), and its database is always disposable.
  def migrate!(extra_env: {}, adapter: nil)
    command = adapter == "mongodb" ? %w[bin/rails db:mongoid:create_indexes] : %w[bin/rails db:create db:schema:load]
    run_job!(command, extra_env: extra_env.merge("DISABLE_DATABASE_ENVIRONMENT_CHECK" => "1"))
  end

  def seed!(extra_env: {})
    run_job!(%w[bin/rails db:seed], extra_env:)
  end

  def run_setup_task!(task, extra_env: {})
    run_job!(["bin/rails", task], extra_env:)
  end

  def stop!
    api.delete(api.path("apps/v1", "deployments", container_name))
    api.delete(api.path("apps/v1", "deployments", worker_container_name))
    api.delete(api.path("v1", "services", container_name))
    api.delete(api.path("v1", "configmaps", overrides_name))
    api.delete(api.path("batch/v1", "jobs"), labelSelector: "govuk-preview-app/preview-id=#{preview.id}")
    persistent_volumes.each_key { |volume| api.delete(api.path("v1", "persistentvolumeclaims", claim_name(volume))) }
  end

  # Sleeping (0) and waking (1) a preview - see PreviewSleeper. The
  # Deployment, Service, ConfigMap and image all stay put, so waking is
  # just the app booting again: no image pull, nothing re-run.
  def scale!(replicas)
    deployment_names.each do |name|
      api.merge_patch(api.path("apps/v1", "deployments", name), { spec: { replicas: replicas } })
    end
  end

  def wait_until_running!
    deployment_names.each { |name| wait_until_available!(name) }
  end

  def exists?
    api.exists?(api.path("apps/v1", "deployments", container_name))
  end

  # The image a running preview was started from - so it can be restarted
  # with different settings without resolving its image again.
  def current_image
    api.get(api.path("apps/v1", "deployments", container_name)).dig("spec", "template", "spec", "containers", 0, "image")
  end

  def running?
    available?(container_name)
  end

  def worker_exists?
    api.exists?(api.path("apps/v1", "deployments", worker_container_name))
  end

  def worker_running?
    available?(worker_container_name)
  end

private

  attr_reader :api

  def overrides_name
    ContainerName.for(preview.slug, suffix: "-overrides")
  end

  def worker_command
    command = app.worker_command
    command.include?("sidekiq") ? [*command, "-c", WORKER_CONCURRENCY.to_s] : command
  end

  def memory
    self.class.memory_for(app)
  end

  def deployment_names
    worker = app.worker_command && !worker_in_web_pod?
    worker ? [container_name, worker_container_name] : [container_name]
  end

  def app
    GovukApps.find(preview.app_name)
  end

  def worker_in_web_pod?
    app.worker_command.present? && app.shared_volumes.present?
  end

  def persistent_volumes
    app.shared_volumes.select { |_, volume| volume["persistent"] }
  end

  def claim_name(volume)
    ContainerName.for(preview.slug, suffix: "-#{volume}")
  end

  # Only ever mounted by the one web pod (its Deployment's Recreate strategy
  # stops the old pod first), so ReadWriteOnce is enough.
  def claim(volume)
    {
      apiVersion: "v1",
      kind: "PersistentVolumeClaim",
      metadata: { name: claim_name(volume), labels: labels("storage") },
      spec: {
        accessModes: %w[ReadWriteOnce],
        resources: { requests: { storage: app.shared_volumes[volume].fetch("size", "1Gi") } },
      },
    }
  end

  def labels(component)
    self.class.labels_for(preview, component)
  end

  def require_image!
    raise KubernetesError, "No image resolved for #{preview.slug}" if image.blank?
  end

  def service
    {
      apiVersion: "v1",
      kind: "Service",
      metadata: { name: container_name, labels: labels("web") },
      spec: {
        selector: { "app.kubernetes.io/instance" => container_name },
        ports: [{ name: "http", port: 80, targetPort: APP_PORT }],
      },
    }
  end

  def deployment(name, component:, env:, command: nil, web: false)
    {
      apiVersion: "apps/v1",
      kind: "Deployment",
      metadata: { name: name, labels: labels(component) },
      spec: {
        replicas: 1,
        strategy: { type: "Recreate" },
        selector: { matchLabels: { "app.kubernetes.io/instance" => name } },
        template: {
          metadata: { labels: labels(component).merge("app.kubernetes.io/instance" => name) },
          spec: pod_spec(env:, command:, web:, with_worker: web && worker_in_web_pod?),
        },
      },
    }
  end

  def pod_spec(env:, command: nil, web: false, restart_policy: "Always", with_worker: false)
    containers = [container("app", env:, command:, web:)]
    containers << container("worker", env:, command: worker_command, shared_volumes: true) if with_worker

    {
      restartPolicy: restart_policy,
      # Previews run arbitrary branch code - they have no business talking
      # to the Kubernetes API, and Preview App's own token is never theirs.
      automountServiceAccountToken: false,
      # Otherwise every pod gets <SERVICE>_PORT-style env vars for every
      # other preview's Service in the namespace - e.g. a Service named
      # `redis` injects REDIS_PORT=tcp://..., which some apps misread.
      enableServiceLinks: false,
      securityContext: {
        runAsUser: APP_UID,
        runAsGroup: APP_UID,
        # So the app can write to its volumes, whoever they were created as.
        fsGroup: (APP_UID if web && app.shared_volumes.present?),
        seccompProfile: { type: "RuntimeDefault" },
      }.compact,
      containers:,
      volumes: [
        { name: "overrides", configMap: { name: overrides_name } },
        *(web ? shared_volume_sources : []),
      ],
    }
  end

  def shared_volume_sources
    app.shared_volumes.map do |volume, settings|
      source = settings["persistent"] ? { persistentVolumeClaim: { claimName: claim_name(volume) } } : { emptyDir: {} }
      { name: "shared-#{volume}", **source }
    end
  end

  def container(name, env:, command: nil, web: false, shared_volumes: web)
    container = {
      name:,
      image: image,
      # A local image (see ImageResolver) only exists on the kind node it
      # was loaded onto - there's nowhere to pull it from.
      imagePullPolicy: ImageResolver.local_image?(image) ? "Never" : "IfNotPresent",
      env: PreviewEnv.for(preview, env, web:).map { |key, value| { name: key, value: value } },
      resources: {
        requests: {
          cpu: ENV.fetch("PREVIEW_APP_POD_CPU_REQUEST", "50m"),
          memory: memory[:request],
        },
        limits: { memory: memory[:limit] },
      },
      securityContext: self.class.container_security_context,
      volumeMounts: [
        { name: "overrides", mountPath: OVERRIDES_PATH, subPath: OVERRIDES_KEY, readOnly: true },
        *(shared_volumes ? app.shared_volumes.map { |volume, settings| { name: "shared-#{volume}", mountPath: settings.fetch("path") } } : []),
      ],
    }
    container[:command] = command if command
    if web
      container[:ports] = [{ name: "http", containerPort: APP_PORT }]
      container[:readinessProbe] = { tcpSocket: { port: APP_PORT }, periodSeconds: 5 }
    end
    container
  end

  def run_job!(command, extra_env:)
    require_image!

    name = ContainerName.for(preview.slug, suffix: "-#{SecureRandom.hex(3)}")
    api.create(
      api.path("batch/v1", "jobs"),
      {
        apiVersion: "batch/v1",
        kind: "Job",
        metadata: { name: name, labels: labels("task") },
        spec: {
          backoffLimit: 0,
          activeDeadlineSeconds: task_timeout,
          ttlSecondsAfterFinished: 3600,
          template: {
            metadata: { labels: labels("task") },
            spec: pod_spec(env: extra_env, command:, restart_policy: "Never"),
          },
        },
      },
    )

    wait_for_job!(name, command)
  end

  def wait_for_job!(name, command)
    deadline = Time.current + task_timeout + 60

    loop do
      status = api.get(api.path("batch/v1", "jobs", name)).fetch("status", {})
      return if status["succeeded"].to_i.positive?

      failed = status["failed"].to_i.positive? ||
        Array(status["conditions"]).any? { |c| c["type"] == "Failed" && c["status"] == "True" }
      raise KubernetesError, "#{command.join(' ')} failed: #{job_failure(name, status)}" if failed
      raise KubernetesError, "#{command.join(' ')} did not finish within #{task_timeout}s" if Time.current > deadline

      inspect_pods!("job-name=#{name}")

      pause
    end
  end

  # The task's own output if it got as far as running - otherwise (e.g. it
  # hit its deadline while never scheduled, and Kubernetes has deleted its
  # pod) whatever Kubernetes says about why the Job failed.
  def job_failure(name, status)
    pod = api.get(api.path("v1", "pods"), labelSelector: "job-name=#{name}").fetch("items", []).first
    if pod.nil?
      condition = Array(status["conditions"]).find { |c| c["type"] == "Failed" }
      return condition&.fetch("message", nil).presence || "it never started"
    end

    PreviewEnv.relevant_error(
      api.get_text(api.path("v1", "pods", pod.dig("metadata", "name"), "log"), tailLines: 100),
    )
  rescue KubernetesApi::Error => e
    "(couldn't read logs: #{e.message})"
  end

  def available?(name)
    api.get(api.path("apps/v1", "deployments", name)).dig("status", "availableReplicas").to_i.positive?
  rescue KubernetesApi::NotFound
    false
  end

  # Whether the Deployment's latest version is fully rolled out - the same
  # test as `kubectl rollout status`. Merely having an available pod isn't
  # enough: straight after a Deployment is re-applied (e.g. restarted with
  # new dependency addresses), the *old* pod still counts as available
  # until Kubernetes replaces it, so callers would carry on - and e.g. run
  # a resync task - before the new settings are actually in use.
  def rolled_out?(name)
    deployment = api.get(api.path("apps/v1", "deployments", name))
    replicas = deployment.dig("spec", "replicas") || 1
    status = deployment.fetch("status", {})

    status["observedGeneration"].to_i >= deployment.dig("metadata", "generation").to_i &&
      %w[replicas updatedReplicas availableReplicas].all? { |field| status[field].to_i == replicas }
  rescue KubernetesApi::NotFound
    false
  end

  def wait_until_available!(name)
    deadline = Time.current + start_timeout

    until rolled_out?(name)
      raise KubernetesError, "#{name} did not become ready within #{start_timeout}s" if Time.current > deadline

      inspect_pods!("app.kubernetes.io/instance=#{name}")

      pause
    end
  end

  # Checks on pods that aren't ready yet: fails fast if one can never get
  # its image, and keeps the preview's status message honest if one is
  # waiting for room in the cluster.
  def inspect_pods!(label_selector)
    pods = api.get(api.path("v1", "pods"), labelSelector: label_selector).fetch("items", [])
    self.class.report_scheduling(preview, pods)

    pods.each do |pod|
      pod.dig("status", "containerStatuses").to_a.each do |container|
        reason = container.dig("state", "waiting", "reason")
        next unless UNRECOVERABLE_IMAGE_REASONS.include?(reason)

        hint = ImageResolver.local_image?(container["image"]) ? " - has it been built and loaded with bin/preview-build?" : ""
        raise KubernetesError, "Can't use image #{container['image']} (#{reason})#{hint}"
      end
    end
  end

  def start_timeout
    ENV.fetch("PREVIEW_APP_START_TIMEOUT_SECONDS", 600).to_i
  end

  def task_timeout
    ENV.fetch("PREVIEW_APP_TASK_TIMEOUT_SECONDS", 900).to_i
  end

  def pause
    sleep POLL_INTERVAL
  end
end

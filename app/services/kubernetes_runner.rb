# Runs a preview's app as a Deployment + Service in the previews namespace,
# its optional worker as a second Deployment from the same image, and its
# one-off rake tasks (migrate/seed/setup_tasks) as Jobs.
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

  # What every app/worker/task pod asks for - also what PreviewCapacity
  # adds up to work out how much room a whole preview stack needs.
  def self.memory_request
    ENV.fetch("PREVIEW_APP_POD_MEMORY_REQUEST", "384Mi")
  end

  def self.memory_limit
    ENV.fetch("PREVIEW_APP_POD_MEMORY_LIMIT", "1536Mi")
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

  # The fixes ConfigOverrides used to write into a checkout before
  # `docker build` - mounted into every pod instead, since the image is
  # prebuilt and can't be modified.
  def prepare!
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
  # alongside our own explicit #seed! call.
  def migrate!(extra_env: {})
    run_job!(%w[bin/rails db:create db:schema:load], extra_env:)
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
    command = GovukApps.find(preview.app_name).worker_command
    command.include?("sidekiq") ? [*command, "-c", WORKER_CONCURRENCY.to_s] : command
  end

  def deployment_names
    worker = GovukApps.find(preview.app_name).worker_command
    worker ? [container_name, worker_container_name] : [container_name]
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
          spec: pod_spec(env:, command:, web:),
        },
      },
    }
  end

  def pod_spec(env:, command: nil, web: false, restart_policy: "Always")
    container = {
      name: "app",
      image: image,
      # A local image (see ImageResolver) only exists on the kind node it
      # was loaded onto - there's nowhere to pull it from.
      imagePullPolicy: ImageResolver.local_image?(image) ? "Never" : "IfNotPresent",
      env: PreviewEnv.for(preview, env, web:).map { |key, value| { name: key, value: value } },
      resources: {
        requests: {
          cpu: ENV.fetch("PREVIEW_APP_POD_CPU_REQUEST", "50m"),
          memory: self.class.memory_request,
        },
        limits: { memory: self.class.memory_limit },
      },
      securityContext: self.class.container_security_context,
      volumeMounts: [{ name: "overrides", mountPath: OVERRIDES_PATH, subPath: OVERRIDES_KEY, readOnly: true }],
    }
    container[:command] = command if command
    if web
      container[:ports] = [{ name: "http", containerPort: APP_PORT }]
      container[:readinessProbe] = { tcpSocket: { port: APP_PORT }, periodSeconds: 5 }
    end

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
        seccompProfile: { type: "RuntimeDefault" },
      },
      containers: [container],
      volumes: [{ name: "overrides", configMap: { name: overrides_name } }],
    }
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

  def wait_until_available!(name)
    deadline = Time.current + start_timeout

    until available?(name)
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

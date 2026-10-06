# One dedicated, never-shared database per preview - MySQL, Postgres or
# MongoDB - as a single-replica StatefulSet with its own small persistent
# volume and a Service of the same name - so the URL handed to the app's
# own pods (`<adapter>://<user>@<service name>/app_preview`, as
# DATABASE_URL, or MONGODB_URI for Mongoid apps) resolves within the
# namespace.
#
# The volume is what lets a preview survive its pod being rescheduled (a
# node being replaced, or a preview being put to sleep and woken again)
# without losing whatever's been published into it.
class KubernetesDatabaseRunner
  class DatabaseError < KubernetesApi::Error; end

  DATABASE_NAME = "app_preview".freeze
  MYSQL_ROOT_PASSWORD = "root".freeze
  # The official mysql/postgres/mongo images all run as this uid when not
  # started as root - which the namespace's `restricted` Pod Security
  # standard won't allow.
  DATABASE_UID = 999
  VOLUME_MOUNT = "/var/lib/preview-data".freeze
  POLL_INTERVAL = 3

  attr_reader :preview, :database

  # See KubernetesRunner.memory_for.
  def self.memory_for(database)
    {
      request: database.memory&.fetch("request", nil) || ENV.fetch("PREVIEW_APP_DATABASE_MEMORY_REQUEST", "256Mi"),
      limit: database.memory&.fetch("limit", nil) || ENV.fetch("PREVIEW_APP_DATABASE_MEMORY_LIMIT", "1Gi"),
    }
  end

  def initialize(preview, database, api: KubernetesApi.new)
    @preview = preview
    @database = database
    @api = api
  end

  def container_name
    ContainerName.for(preview.slug, suffix: "-db", max_length: 52)
  end

  def start!
    api.apply(api.path("v1", "services", container_name), service)
    api.apply(api.path("apps/v1", "statefulsets", container_name), stateful_set)
    wait_until_ready!
    database_url
  end

  def stop!
    api.delete(api.path("apps/v1", "statefulsets", container_name))
    api.delete(api.path("v1", "services", container_name))
    api.delete(api.path("v1", "persistentvolumeclaims", "data-#{container_name}-0"))
  end

  # Sleeping (0) and waking (1) - see PreviewSleeper. The volume stays
  # (persistentVolumeClaimRetentionPolicy whenScaled: Retain), so the
  # preview wakes up with everything that had been published into it.
  def scale!(replicas)
    api.merge_patch(api.path("apps/v1", "statefulsets", container_name), { spec: { replicas: replicas } })
  end

  def wait_until_ready!
    deadline = Time.current + timeout

    until ready?
      raise DatabaseError, "Database did not become ready within #{timeout}s" if Time.current > deadline

      KubernetesRunner.report_scheduling(
        preview, api.get(api.path("v1", "pods"), labelSelector: "app.kubernetes.io/instance=#{container_name}").fetch("items", [])
      )
      pause
    end
  end

  def exists?
    api.exists?(api.path("apps/v1", "statefulsets", container_name))
  end

  def database_url
    case database.adapter
    # MySQL's root user gets a password (not secret - nothing outside the
    # previews namespace can reach it) because Rails merges DATABASE_URL into
    # the app's own database.yml: with no password in the URL, an app's own
    # `password:` (e.g. Collections Publisher's) would be tried for root
    # instead, and refused.
    when "mysql2" then "mysql2://root:#{MYSQL_ROOT_PASSWORD}@#{container_name}/#{DATABASE_NAME}"
    when "postgresql" then "postgresql://postgres@#{container_name}/#{DATABASE_NAME}"
    when "mongodb" then "mongodb://#{container_name}/#{DATABASE_NAME}"
    else raise DatabaseError, "Unknown database adapter: #{database.adapter}"
    end
  end

  # The env var the app reads its database's address from - Mongoid apps'
  # config/mongoid.yml reads MONGODB_URI; ActiveRecord apps, DATABASE_URL.
  def env_var
    database.adapter == "mongodb" ? "MONGODB_URI" : "DATABASE_URL"
  end

private

  attr_reader :api

  def labels
    KubernetesRunner.labels_for(preview, "database")
  end

  def service
    {
      apiVersion: "v1",
      kind: "Service",
      metadata: { name: container_name, labels: labels },
      spec: {
        selector: { "app.kubernetes.io/instance" => container_name },
        ports: [{ name: "db", port: port, targetPort: port }],
      },
    }
  end

  def stateful_set
    {
      apiVersion: "apps/v1",
      kind: "StatefulSet",
      metadata: { name: container_name, labels: labels },
      spec: {
        replicas: 1,
        serviceName: container_name,
        selector: { matchLabels: { "app.kubernetes.io/instance" => container_name } },
        persistentVolumeClaimRetentionPolicy: { whenDeleted: "Delete", whenScaled: "Retain" },
        template: {
          metadata: { labels: labels.merge("app.kubernetes.io/instance" => container_name) },
          spec: {
            automountServiceAccountToken: false,
            enableServiceLinks: false,
            securityContext: {
              runAsUser: DATABASE_UID,
              runAsGroup: DATABASE_UID,
              fsGroup: DATABASE_UID,
              seccompProfile: { type: "RuntimeDefault" },
            },
            containers: [container],
          },
        },
        volumeClaimTemplates: [volume_claim_template],
      },
    }
  end

  def container
    {
      name: "database",
      image: database.image,
      command: command,
      args: args,
      env: init_env.map { |key, value| { name: key, value: value } },
      ports: [{ name: "db", containerPort: port }],
      readinessProbe: { exec: { command: ready_command }, periodSeconds: 3 },
      resources: {
        requests: { cpu: "50m", memory: self.class.memory_for(database)[:request] },
        limits: { memory: self.class.memory_for(database)[:limit] },
      },
      securityContext: KubernetesRunner.container_security_context,
      volumeMounts: [{ name: "data", mountPath: VOLUME_MOUNT }],
    }.compact
  end

  def volume_claim_template
    spec = {
      accessModes: %w[ReadWriteOnce],
      resources: { requests: { storage: ENV.fetch("PREVIEW_APP_DATABASE_VOLUME_SIZE", "1Gi") } },
    }
    storage_class = ENV["PREVIEW_APP_DATABASE_STORAGE_CLASS"]
    spec[:storageClassName] = storage_class if storage_class.present?

    { metadata: { name: "data" }, spec: spec }
  end

  # The official mongo image's entrypoint doesn't create a custom --dbpath
  # when it isn't started as root, so this does first. (mysql/postgres
  # create their own data directories, so keep their images' defaults.)
  def command
    return unless database.adapter == "mongodb"

    ["bash", "-c", "mkdir -p #{VOLUME_MOUNT}/mongo && exec docker-entrypoint.sh \"$@\"", "--"]
  end

  # Each image refuses to initialise into a non-empty directory, and a
  # freshly-formatted volume's root already holds lost+found - so each
  # keeps its data one level down.
  #
  # The rest sizes each server for a preview's tiny amount of data and a
  # handful of connections, rather than the images' production-minded
  # defaults - MySQL 8's performance schema alone takes a couple of hundred
  # MB, and its default buffer pool another 128MB.
  def args
    case database.adapter
    when "mysql2"
      %W[
        --datadir=#{VOLUME_MOUNT}/mysql
        --performance-schema=OFF
        --innodb-buffer-pool-size=32M
        --innodb-log-buffer-size=8M
        --max-connections=50
        --table-open-cache=200
        --skip-name-resolve
      ]
    when "postgresql"
      %w[-c shared_buffers=16MB -c max_connections=40 -c work_mem=2MB]
    when "mongodb"
      # WiredTiger otherwise takes half the container's memory for its cache.
      %W[mongod --dbpath #{VOLUME_MOUNT}/mongo --bind_ip_all --wiredTigerCacheSizeGB 0.25]
    else
      []
    end
  end

  def init_env
    case database.adapter
    when "mysql2"
      { "MYSQL_ROOT_PASSWORD" => MYSQL_ROOT_PASSWORD, "MYSQL_DATABASE" => DATABASE_NAME }
    when "postgresql"
      { "POSTGRES_HOST_AUTH_METHOD" => "trust", "POSTGRES_DB" => DATABASE_NAME, "PGDATA" => "#{VOLUME_MOUNT}/postgres" }
    when "mongodb"
      {} # No auth, and databases are created on first write.
    else
      raise DatabaseError, "Unknown database adapter: #{database.adapter}"
    end
  end

  def port
    { "mysql2" => 3306, "postgresql" => 5432, "mongodb" => 27_017 }.fetch(database.adapter)
  end

  # Over TCP, not the Unix socket: both official images run a short-lived
  # *temporary* init server (Unix socket only) before their real restart on
  # TCP - a socket-based check answers "ready" during that false start.
  READY_COMMANDS = {
    "mysql2" => ["mysqladmin", "ping", "-h", "127.0.0.1", "-uroot", "-p#{MYSQL_ROOT_PASSWORD}", "--silent"],
    "postgresql" => ["pg_isready", "-U", "postgres", "-h", "127.0.0.1"],
    "mongodb" => ["mongosh", "--quiet", "--host", "127.0.0.1", "--eval", "db.adminCommand('ping').ok"],
  }.freeze

  def ready_command
    READY_COMMANDS.fetch(database.adapter)
  end

  def ready?
    api.get(api.path("apps/v1", "statefulsets", container_name)).dig("status", "readyReplicas").to_i.positive?
  end

  # Covers a volume being provisioned and an image pull, on top of the
  # database's own startup.
  def timeout
    ENV.fetch("PREVIEW_APP_DATABASE_TIMEOUT_SECONDS", 300).to_i
  end

  def pause
    sleep POLL_INTERVAL
  end
end

require "open3"

# Starts/stops a plain database container for a single preview - one per
# preview, never shared, matching the "disposable container" model already
# used for the app itself. No host port is published: it's only reachable
# by sibling containers via Docker's embedded DNS, the same mechanism
# HostRouter already relies on to reach preview containers.
class DatabaseRunner
  class DatabaseError < StandardError; end

  READINESS_TIMEOUT = 30
  DATABASE_NAME = "app_preview".freeze

  attr_reader :preview, :database

  def initialize(preview, database)
    @preview = preview
    @database = database
  end

  def container_name
    "govuk-preview-app-#{preview.slug}-db"
  end

  def start!
    # Idempotent: a Sidekiq retry after a partial failure shouldn't collide
    # on a container name a previous, interrupted attempt already created.
    Open3.capture3("docker", "rm", "-f", container_name)

    run!("docker", "run", "-d", "--name", container_name, "--network", network_name, *init_env_args, database.image)
    wait_until_ready!
    database_url
  end

  def stop!
    Open3.capture3("docker", "stop", container_name)
    Open3.capture3("docker", "rm", container_name)
  end

  def database_url
    case database.adapter
    when "mysql2" then "mysql2://root@#{container_name}/#{DATABASE_NAME}"
    when "postgresql" then "postgresql://postgres@#{container_name}/#{DATABASE_NAME}"
    else raise DatabaseError, "Unknown database adapter: #{database.adapter}"
    end
  end

private

  def init_env_args
    case database.adapter
    when "mysql2"
      ["-e", "MYSQL_ALLOW_EMPTY_PASSWORD=yes", "-e", "MYSQL_DATABASE=#{DATABASE_NAME}"]
    when "postgresql"
      ["-e", "POSTGRES_HOST_AUTH_METHOD=trust", "-e", "POSTGRES_DB=#{DATABASE_NAME}"]
    else
      raise DatabaseError, "Unknown database adapter: #{database.adapter}"
    end
  end

  def ready?
    check = case database.adapter
            # -h 127.0.0.1, not "localhost": the mysql client treats
            # "localhost" as "use the unix socket", which the official
            # image's short-lived *temporary* init server (before its
            # real restart) also answers on - forcing TCP is what
            # actually distinguishes "really ready" from that false start.
            when "mysql2" then ["docker", "exec", container_name, "mysqladmin", "ping", "-h", "127.0.0.1", "--silent"]
            when "postgresql" then ["docker", "exec", container_name, "pg_isready", "-U", "postgres"]
            end

    _out, _err, status = Open3.capture3(*check)
    status.success?
  end

  def wait_until_ready!
    deadline = Time.current + READINESS_TIMEOUT

    until ready?
      raise DatabaseError, "Database did not become ready within #{READINESS_TIMEOUT}s" if Time.current > deadline

      sleep 1
    end
  end

  def network_name
    ENV.fetch("PREVIEW_APP_DOCKER_NETWORK", "govuk-preview-app_default")
  end

  def run!(*command)
    out, err, status = Open3.capture3(*command)
    raise DatabaseError, err unless status.success?

    out
  end
end

require "open3"
require "securerandom"

class DockerRunner
  class DockerError < StandardError; end

  attr_reader :preview

  def initialize(preview)
    @preview = preview
  end

  def image_tag
    "govuk-app-preview/#{preview.app_name}:#{preview.slug}"
  end

  def container_name
    "govuk-app-preview-#{preview.slug}"
  end

  def build!(checkout_path)
    run!("docker", "build", "-t", image_tag, checkout_path.to_s)
  end

  # publish_port: false for a dependency preview - it's only ever reached by
  # sibling containers via Docker's embedded DNS (see HostRouter), never
  # published to the host or made hostname-routable. preview.port is still
  # allocated and passed via the app's own PORT env var either way, since
  # that's what sibling containers address it by.
  def start!(extra_env: {}, publish_port: true)
    port_flags = publish_port ? ["-p", "#{preview.port}:#{preview.port}"] : []

    # Idempotent: a Sidekiq retry after a partial failure shouldn't collide
    # on a container name a previous, interrupted attempt already created.
    Open3.capture3("docker", "rm", "-f", container_name)

    container_id, = run!(
      "docker", "run", "-d",
      "--name", container_name,
      "--network", network_name,
      *port_flags,
      *env_args(extra_env),
      image_tag
    )

    container_id.strip
  end

  # A one-off, auto-removed container running the same image/env as start!,
  # to prepare a freshly-started database before the long-running container
  # begins. db:prepare alone (not db:seed too) is deliberate: db:prepare
  # already runs db:seed itself the first time it creates a database (see
  # ActiveRecord::Tasks::DatabaseTasks#prepare_all) - since every preview's
  # database is freshly created, adding an explicit db:seed here would run
  # an app's seeds.rb a second time in the same invocation, which broke
  # Whitehall's (its seeds.rb calls the non-idempotent Organisation.
  # skip_callback, which raises if the first, implicit seed run already
  # removed that callback).
  def migrate!(extra_env: {})
    run!(
      "docker", "run", "--rm",
      "--network", network_name,
      *env_args(extra_env),
      image_tag,
      "bin/rails", "db:prepare"
    )
  end

  def stop!
    run!("docker", "stop", container_name) if running?
    run!("docker", "rm", container_name) if exists?
  end

  def running?
    out, = Open3.capture3("docker", "inspect", "-f", "{{.State.Running}}", container_name)
    out.strip == "true"
  end

  def exists?
    _out, _err, status = Open3.capture3("docker", "inspect", container_name)
    status.success?
  end

private

  # So sibling preview containers are resolvable by name (via Docker's
  # embedded DNS) from this app's own container - see HostRouter, and
  # DatabaseRunner, which both rely on this.
  def network_name
    ENV.fetch("APP_PREVIEW_DOCKER_NETWORK", "govuk-app-preview_default")
  end

  # SECRET_KEY_BASE is needed for any Rails app to boot at all in production
  # mode (which the base GOV.UK Docker images run in by default) - it's not
  # app-specific, so every preview container gets its own random one.
  # RAILS_SERVE_STATIC_FILES: in real production, static assets are served by
  # a separate layer (CDN/asset host), not Rails itself - most GOV.UK apps'
  # own production.rb gates config.public_file_server.enabled on this env var
  # (a few, e.g. Whitehall, always enable it regardless, in which case this
  # is simply a no-op). There's no separate asset-serving layer here, so
  # every preview needs Rails to serve its own assets directly.
  # GDS_SSO_STRATEGY: forces gds-sso's mock auth strategy regardless of
  # RAILS_ENV (verified working for App Preview's own gds-sso setup, and for
  # Whitehall/Publishing API's) - harmless for apps that don't use gds-sso.
  # REDIS_URL: govuk_sidekiq's railtie eagerly connects to Redis at boot for
  # *any* rake task, not just when a worker actually runs - so any app using
  # that gem (most GOV.UK admin apps) needs a reachable Redis just to boot.
  # We're not running previewed apps' own workers this pass, so pointing
  # every preview at App Preview's own shared Redis (already on the same
  # network) is harmless - nothing reads the queues it'd write to.
  # Beyond these, each app's manifest entry can declare a fixed set of extra
  # env vars (e.g. pointing an app's Plek-resolved dependencies at real
  # GOV.UK services), and `extra_env` carries per-instance values resolved
  # at build time (a dependency's own PLEK_SERVICE_*_URI, DATABASE_URL) that
  # can't live in the static manifest - see config/govuk_apps.yml.
  def env_args(extra_env)
    app = GovukApps.find(preview.app_name)

    env = {
      app.port_env_var => preview.port,
      "SECRET_KEY_BASE" => SecureRandom.hex(32),
      "RAILS_SERVE_STATIC_FILES" => "true",
      "GDS_SSO_STRATEGY" => "mock",
      "REDIS_URL" => "redis://redis:6379",
    }.merge(app.env).merge(extra_env)

    env.flat_map { |key, value| ["-e", "#{key}=#{value}"] }
  end

  def run!(*command)
    out, err, status = Open3.capture3(*command)
    raise DockerError, err unless status.success?

    [out, err]
  end
end

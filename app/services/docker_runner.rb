require "open3"
require "securerandom"

class DockerRunner
  class DockerError < StandardError; end

  attr_reader :preview

  def initialize(preview)
    @preview = preview
  end

  # Guards PreviewReconciler against a false-positive mass reconciliation -
  # if the Docker socket/daemon itself isn't reachable yet (e.g. right at
  # boot), every container existence check below would fail, which would
  # otherwise look identical to every preview's containers actually having
  # disappeared.
  def self.daemon_reachable?
    _out, _err, status = Open3.capture3("docker", "info")
    status.success?
  end

  def image_tag
    "govuk-preview-app/#{preview.app_name}:#{preview.slug}"
  end

  def container_name
    ContainerName.for(preview.slug)
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
  # to create the schema on a freshly-started database before the
  # long-running container begins. Deliberately db:create db:schema:load,
  # not db:prepare: db:prepare also seeds the database itself the first
  # time it creates one (see ActiveRecord::Tasks::DatabaseTasks#
  # prepare_all), which would double-seed alongside our own explicit
  # #seed! call below.
  def migrate!(extra_env: {})
    run!(
      "docker", "run", "--rm",
      "--network", network_name,
      *env_args(extra_env),
      image_tag,
      "bin/rails", "db:create", "db:schema:load"
    )
  end

  # A one-off, auto-removed container running an app's db/seeds.rb,
  # deliberately a separate step from migrate! (see above).
  def seed!(extra_env: {})
    run!(
      "docker", "run", "--rm",
      "--network", network_name,
      *env_args(extra_env),
      image_tag,
      "bin/rails", "db:seed"
    )
  end

  # A one-off, auto-removed container running an arbitrary `bin/rails` task -
  # see the manifest's `setup_tasks` (e.g. seeding a dependency with data
  # only this app's own fixtures/rake tasks know how to create, rather than
  # Preview App hardcoding that knowledge itself).
  def run_setup_task!(task, extra_env: {})
    run!(
      "docker", "run", "--rm",
      "--network", network_name,
      *env_args(extra_env),
      image_tag,
      "bin/rails", task
    )
  end

  def stop!
    run!("docker", "stop", container_name) if running?
    run!("docker", "rm", container_name) if exists?

    stop_worker!
  end

  def running?
    out, = Open3.capture3("docker", "inspect", "-f", "{{.State.Running}}", container_name)
    out.strip == "true"
  end

  def exists?
    _out, _err, status = Open3.capture3("docker", "inspect", container_name)
    status.success?
  end

  def worker_container_name
    ContainerName.for(preview.slug, suffix: "-worker")
  end

  # A second, long-running container from the same built image, running the
  # manifest's `worker_command` instead of the app's own web server - e.g.
  # Publishing API's Sidekiq worker, which pushes published content
  # downstream to Content Store.
  def start_worker!(extra_env: {})
    Open3.capture3("docker", "rm", "-f", worker_container_name)

    run!(
      "docker", "run", "-d",
      "--name", worker_container_name,
      "--network", network_name,
      *env_args(extra_env),
      image_tag,
      *GovukApps.find(preview.app_name).worker_command
    )
  end

  def stop_worker!
    return unless GovukApps.find(preview.app_name).worker_command

    run!("docker", "stop", worker_container_name) if worker_running?
    run!("docker", "rm", worker_container_name) if worker_exists?
  end

  def worker_running?
    out, = Open3.capture3("docker", "inspect", "-f", "{{.State.Running}}", worker_container_name)
    out.strip == "true"
  end

  def worker_exists?
    _out, _err, status = Open3.capture3("docker", "inspect", worker_container_name)
    status.success?
  end

private

  # So sibling preview containers are resolvable by name (via Docker's
  # embedded DNS) from this app's own container - see HostRouter, and
  # DatabaseRunner, which both rely on this.
  def network_name
    ENV.fetch("PREVIEW_APP_DOCKER_NETWORK", "govuk-preview-app_default")
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
  # RAILS_ENV (verified working for Preview App's own gds-sso setup, and for
  # Whitehall/Publishing API's) - harmless for apps that don't use gds-sso.
  # REDIS_URL: govuk_sidekiq's railtie eagerly connects to Redis at boot for
  # *any* rake task, not just when a worker actually runs - so any app using
  # that gem (most GOV.UK admin apps) needs a reachable Redis just to boot.
  # We're not running previewed apps' own workers this pass, so pointing
  # every preview at Preview App's own shared Redis (already on the same
  # network) is harmless - nothing reads the queues it'd write to.
  # GOVUK_WEBSITE_ROOT: a standard Plek/GOV.UK env var (not app-specific) -
  # some apps gate integration/staging-only behaviour on it containing
  # "integration"/"staging" (e.g. Whitehall's /flipflop dashboard access
  # filter, Whitehall.integration_or_staging?) - previews are integration-
  # like environments, so this makes that recognised rather than silently
  # blocked under RAILS_ENV=production.
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
      "GOVUK_WEBSITE_ROOT" => "https://www.integration.publishing.service.gov.uk",
    }.merge(app.env).merge(extra_env)

    env.flat_map { |key, value| ["-e", "#{key}=#{value}"] }
  end

  def run!(*command)
    out, err, status = Open3.capture3(*command)
    raise DockerError, extract_error(err) unless status.success?

    [out, err]
  end

  # A failing `bin/rails` invocation's stderr is usually preceded by
  # unrelated boilerplate (a container home-directory warning, Bundler's
  # tmpdir notice) - callers that truncate this (e.g. PreviewBuilder's
  # status_message) would otherwise keep only that noise and lose the
  # actual error. Start from "bin/rails aborted!" when present; a
  # `docker build` failure (no such marker) falls back to the raw text.
  def extract_error(err)
    marker = err.index("bin/rails aborted!")
    marker ? err[marker..] : err
  end
end

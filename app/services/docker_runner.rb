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

  def start!
    container_id, = run!(
      "docker", "run", "-d",
      "--name", container_name,
      "--network", network_name,
      "-p", "#{preview.port}:#{preview.port}",
      *env_args,
      image_tag
    )

    container_id.strip
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
  # PreviewsCreateJob's readiness wait, which both rely on this.
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
  # HEROKU_APP_NAME: frontend's own production.rb sets
  # config.action_dispatch.x_sendfile_header to "X-Sendfile" unless this is
  # set - which makes Rails hand back an *empty* asset body, trusting an
  # Apache-style front end to intercept that header and serve the file
  # itself. Our nginx doesn't have filesystem access to a preview
  # container's files at all, so it can't act on X-Sendfile (or nginx's own
  # X-Accel-Redirect equivalent) either way - the only fix is getting the
  # app to serve the body itself, and this is the escape hatch frontend
  # happens to have for that. Not a general GOV.UK convention (e.g.
  # Whitehall hardcodes X-Accel-Redirect with no such override) - noted as
  # a rough edge for when a second app is added, not solved universally here.
  # Beyond these, each app's manifest entry can declare a fixed set of extra
  # env vars (e.g. pointing an app's Plek-resolved dependencies at real
  # GOV.UK services) - see config/govuk_apps.yml.
  def env_args
    app = GovukApps.find(preview.app_name)

    env = {
      app.port_env_var => preview.port,
      "SECRET_KEY_BASE" => SecureRandom.hex(32),
      "RAILS_SERVE_STATIC_FILES" => "true",
      "HEROKU_APP_NAME" => "govuk-app-preview",
    }.merge(app.env)

    env.flat_map { |key, value| ["-e", "#{key}=#{value}"] }
  end

  def run!(*command)
    out, err, status = Open3.capture3(*command)
    raise DockerError, err unless status.success?

    [out, err]
  end
end

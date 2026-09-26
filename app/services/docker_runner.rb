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

  # SECRET_KEY_BASE is needed for any Rails app to boot at all in production
  # mode (which the base GOV.UK Docker images run in by default) - it's not
  # app-specific, so every preview container gets its own random one. Beyond
  # that, each app's manifest entry can declare a fixed set of extra env vars
  # (e.g. pointing an app's Plek-resolved dependencies at real GOV.UK
  # services) - see config/govuk_apps.yml.
  def env_args
    app = GovukApps.find(preview.app_name)

    env = { app.port_env_var => preview.port, "SECRET_KEY_BASE" => SecureRandom.hex(32) }.merge(app.env)

    env.flat_map { |key, value| ["-e", "#{key}=#{value}"] }
  end

  def run!(*command)
    out, err, status = Open3.capture3(*command)
    raise DockerError, err unless status.success?

    [out, err]
  end
end

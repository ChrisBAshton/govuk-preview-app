require "open3"

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
    port_env_var = GovukApps.find(preview.app_name).port_env_var

    container_id, = run!(
      "docker", "run", "-d",
      "--name", container_name,
      "-p", "#{preview.port}:#{preview.port}",
      "-e", "#{port_env_var}=#{preview.port}",
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

  def run!(*command)
    out, err, status = Open3.capture3(*command)
    raise DockerError, err unless status.success?

    [out, err]
  end
end

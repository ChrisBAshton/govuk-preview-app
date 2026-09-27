# Drives a Preview through checking_out -> building -> starting -> running,
# including its dependencies (each its own dedicated, never-shared Preview -
# see Preview#generate_slug) and, if the app needs one, a database. Extracted
# from PreviewsCreateJob so a dependency can be built by calling this
# directly rather than re-entering Sidekiq.
class PreviewBuilder
  class DependencyError < StandardError; end

  RESCUED_ERRORS = [
    Checkout::GitError,
    DockerRunner::DockerError,
    PortAllocator::NoPortsAvailableError,
    DatabaseRunner::DatabaseError,
    DependencyError,
  ].freeze

  attr_reader :preview

  def initialize(preview)
    @preview = preview
  end

  def build!
    return if preview.running?

    app = GovukApps.find(preview.app_name)
    extra_env = build_dependencies!(app)

    checkout = Checkout.new(preview)
    docker = DockerRunner.new(preview)

    preview.update!(status: :checking_out)
    checkout_path = checkout.checkout!
    ConfigOverrides.new(checkout_path).write!

    preview.update!(status: :building)
    docker.build!(checkout_path)

    preview.update!(status: :starting, port: PortAllocator.allocate)

    if app.database
      database_url = DatabaseRunner.new(preview, app.database).start!
      extra_env = extra_env.merge("DATABASE_URL" => database_url)
      docker.migrate!(extra_env: extra_env)
    end

    # Dependency previews are internal-only: reachable by sibling containers
    # via Docker's embedded DNS, never published to the host or made
    # hostname-routable (see HostRouter) - Publishing API, the only
    # dependency today, is an unauthenticated, state-mutating API that
    # shouldn't be reachable at a guessable public-looking subdomain.
    container_id = docker.start!(extra_env: extra_env, publish_port: preview.parent_id.nil?)

    preview.update!(status: :running, container_id: container_id)
  rescue *RESCUED_ERRORS => e
    preview.update!(status: :failed, status_message: e.message.truncate(255))
  end

private

  def build_dependencies!(app)
    app.dependencies.each_with_object({}) do |dep_name, env|
      dependent = Preview.create!(app_name: dep_name, branch: "main", parent: preview)
      self.class.new(dependent).build!

      unless dependent.reload.running?
        raise DependencyError, "dependency #{dep_name} failed to start: #{dependent.status_message}"
      end

      dep_container_name = DockerRunner.new(dependent).container_name
      env["PLEK_SERVICE_#{dep_name.upcase.tr('-', '_')}_URI"] = "http://#{dep_container_name}:#{dependent.port}"
    end
  end
end

# Drives a Preview through waiting_for_image -> starting -> running,
# including its dependencies (each its own dedicated, never-shared Preview -
# see Preview#generate_slug) and, if the app needs one, a database. Extracted
# from PreviewsCreateJob so a dependency can be built by calling this
# directly rather than re-entering Sidekiq.
class PreviewBuilder
  class DependencyError < StandardError; end

  # Where a dependency left out of a core stack points instead - see
  # `full_stack_dependencies` in config/govuk_apps.yml.
  SINK_URI = "http://sink".freeze

  RESCUED_ERRORS = [
    ImageResolver::ImageError,
    KubernetesApi::Error,
    PreviewCapacity::AtCapacityError,
    DependencyError,
  ].freeze

  attr_reader :preview

  def initialize(preview)
    @preview = preview
  end

  # inherited_env carries PLEK_SERVICE_*_URI entries resolved by dependencies
  # already built *before* this preview, in the same parent's manifest list
  # (see build_dependencies!) - e.g. Whitehall's `frontend` dependency,
  # declared after `publishing-api`, inherits the real local Content Store
  # address that publishing-api's own `content-store` dependency resolved.
  # Returns the same kind of hash (this preview's own inherited env, plus
  # whatever its own dependencies resolved) so a caller building further
  # siblings afterwards can pass it on in turn.
  #
  # Safe to call again on a build that was interrupted part-way (e.g. the
  # Sidekiq worker restarted mid-build, and Sidekiq retried the job):
  # existing dependency previews are reused rather than recreated, anything
  # already running is left alone, and anything that hadn't finished is
  # built again - server-side apply and Jobs make every step re-runnable.
  def build!(inherited_env: {})
    app = GovukApps.find(preview.app_name)

    # Room for the whole stack is made once, up front, by its top-level
    # preview - putting least recently used previews to sleep if need be.
    if preview.parent_id.nil?
      PreviewCapacity.make_room_for!(preview, building: true) unless preview.running?
      StackRedis.new(preview).start!
    end
    propagated_env, own_env = build_dependencies!(app, inherited_env)
    dependency_env = inherited_env.merge(propagated_env)

    # Lets an app read one of its own inherited dependencies' resolved
    # addresses under a *different* env var name, for its own container
    # only - e.g. draft-frontend is the exact same codebase as frontend,
    # which only ever reads PLEK_SERVICE_CONTENT_STORE_URI (never
    # PLEK_SERVICE_DRAFT_CONTENT_STORE_URI) - see config/govuk_apps.yml.
    # Applied on top of dependency_env (not the other way round): by the
    # time a later sibling like draft-frontend is built, dependency_env
    # already holds the *live* PLEK_SERVICE_CONTENT_STORE_URI (inherited
    # from publishing-api's own content-store dependency), so the alias
    # must win here or draft-frontend would silently render the live site.
    # dependency_env itself - returned below for propagation to further
    # siblings/the parent - is deliberately left unaliased.
    aliased_env = app.env_aliases.filter_map { |to_key, from_key|
      [to_key, dependency_env[from_key]] if dependency_env.key?(from_key)
    }.to_h
    # own_env (dependencies this stack leaves out, pointed at the sink) is
    # for this preview only - never passed on, so e.g. Whitehall keeps
    # reading the real GOV.UK Content Store rather than inheriting Publishing
    # API's stand-in for its own.
    extra_env = dependency_env.merge(aliased_env).merge(own_env)

    # Already running (e.g. resuming an interrupted build, or changing the
    # stack's size): nothing to build, but it may need restarting with
    # different dependency addresses - and its own dependencies' addresses
    # still need passing on to its later siblings, as when first built.
    if preview.running?
      reconfigure!(app, extra_env)
      return dependency_env
    end

    # Nothing is built here - see ImageResolver for where images come from.
    preview.update!(status: :waiting_for_image)
    runner = KubernetesRunner.new(preview, image: ImageResolver.new(app, preview.branch).resolve!)

    preview.update!(status: :starting)
    runner.prepare!

    if app.database
      database = KubernetesDatabaseRunner.new(preview, app.database)
      extra_env = extra_env.merge(database.env_var => database.start!)
      runner.migrate!(extra_env: extra_env, adapter: app.database.adapter)
      runner.seed!(extra_env: extra_env)
    end

    app.setup_tasks.each { |task| runner.run_setup_task!(task, extra_env: extra_env) }

    # Dependency previews are internal-only by default: reachable by other
    # previews over cluster DNS, but never hostname-routable - most
    # dependencies (e.g. Publishing API) are unauthenticated, state-mutating
    # APIs that shouldn't be reachable at a guessable public-looking
    # subdomain. A dependency can opt into a stable, public hostname via the
    # manifest's `publicly_readable` (see HostRouter) - only safe for
    # genuinely read-only, non-mutating APIs (e.g. Content Store).
    container_id = runner.start!(extra_env: extra_env)
    runner.start_worker!(extra_env: extra_env) if app.worker_command

    preview.update!(status: :running, container_id: container_id, env_digest: digest(extra_env))

    dependency_env
  rescue *RESCUED_ERRORS => e
    preview.update!(status: :failed, status_message: e.message.truncate(255))
    inherited_env
  end

private

  # Restarts an already-running preview's pods with new dependency
  # addresses if they've changed since it was started - e.g. when its stack
  # is switched to or from the full stack. Only its Deployments are
  # re-applied (same image), so its database is untouched. When the full
  # stack has just been added, its `resync_tasks` then fill the newly-added
  # dependencies (e.g. Publishing API re-sends everything to the new Content
  # Stores).
  def reconfigure!(app, extra_env)
    if app.database
      database = KubernetesDatabaseRunner.new(preview, app.database)
      extra_env = extra_env.merge(database.env_var => database.database_url)
    end
    return if preview.env_digest == digest(extra_env)

    runner = KubernetesRunner.new(preview, image: KubernetesRunner.new(preview).current_image)
    runner.start!(extra_env: extra_env)
    runner.start_worker!(extra_env: extra_env) if app.worker_command
    app.resync_tasks.each { |task| runner.run_setup_task!(task, extra_env: extra_env) } if preview.root.full_stack

    preview.update!(env_digest: digest(extra_env))
  end

  def digest(env)
    Digest::SHA256.hexdigest(env.sort.to_h.to_json)
  end

  def left_out?(app, dep_name)
    app.full_stack_dependencies.include?(dep_name) && !preview.root.full_stack
  end

  # Returns [env passed on to later siblings and the parent, env for this
  # preview alone].
  def build_dependencies!(app, inherited_env)
    own_env = {}

    propagated_env = (app.dependencies + app.full_stack_dependencies).each_with_object({}) do |dep_name, env|
      if left_out?(app, dep_name)
        own_env["PLEK_SERVICE_#{dep_name.upcase.tr('-', '_')}_URI"] = SINK_URI
        next
      end

      dependent = preview.dependents.find_by(app_name: dep_name) ||
        Preview.create!(app_name: dep_name, branch: "main", parent: preview)
      resolved_env = self.class.new(dependent).build!(inherited_env: inherited_env.merge(env))

      unless dependent.reload.running?
        raise DependencyError, "dependency #{dep_name} failed to start: #{dependent.status_message}"
      end

      plek_key = dep_name.upcase.tr("-", "_")
      env["PLEK_SERVICE_#{plek_key}_URI"] = "http://#{KubernetesRunner.new(dependent).container_name}"
      # The internal URI above is only ever reachable by other previews over
      # cluster DNS - fine for server-to-server use (e.g.
      # Frontend's own Content Store lookups), but useless for a link
      # meant to be clicked in a browser (e.g. Whitehall's "Preview on
      # website"). A publicly_readable dependency also gets its real,
      # browser-reachable URL exposed this way.
      env["PLEK_SERVICE_#{plek_key}_PUBLIC_URL"] = dependent.url if dependent.publicly_readable?
      env.merge!(resolved_env)
    end

    [propagated_env, own_env]
  end
end

# Dispatches requests for a running preview's hostname straight to its
# Service in the previews namespace, without ever reaching this app's own routing/auth -
# mirroring the target integration shape (one wildcard entry point -> one
# Preview App process -> internal Host-header dispatch). Requests for
# anything else (the app's own UI, or an unmatched/stale preview subdomain)
# fall through unchanged.
class HostRouter
  def initialize(app)
    @app = app
    @proxy = Rack::Proxy.new
  end

  def call(env)
    preview = matching_preview(env)
    return @app.call(env) unless preview

    env["rack.backend"] = "http://#{KubernetesRunner.new(preview).service_host}"
    @proxy.call(env)
  end

private

  def matching_preview(env)
    host = Rack::Request.new(env).host
    suffix = ".#{Preview.base_domain}"
    return nil unless host.end_with?(suffix)

    prefix = host.delete_suffix(suffix)

    # A dependency preview is internal-only by default, found (if at all)
    # only by its real slug, scoped to parent_id: nil - most (e.g.
    # Publishing API) are unauthenticated, state-mutating APIs that must
    # never be reachable at a guessable public-looking subdomain. A
    # dependency can opt into being routable via the manifest's
    # `publicly_readable` (only safe for a genuinely read-only API, e.g.
    # Content Store) - found instead by its own random `public_hostname`
    # (see Preview#generate_public_hostname), never its real slug, so the
    # public URL never has to expose which parent it actually belongs to.
    Preview.running.where(parent_id: nil).find_by(slug: prefix) ||
      Preview.running.find_by(public_hostname: prefix)
  end
end

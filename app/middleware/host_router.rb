# Dispatches requests for a running preview's hostname straight to its
# Service in the previews namespace, without ever reaching this app's own routing/auth -
# mirroring the target integration shape (one wildcard entry point -> one
# Preview App process -> internal Host-header dispatch). Requests for
# anything else (the app's own UI, or an unmatched/stale preview subdomain)
# fall through unchanged.
#
# Visiting a preview whose stack has been put to sleep (see PreviewSleeper)
# wakes it, showing a self-refreshing "Waking up" page until it's back.
class HostRouter
  ROUTABLE_STATUSES = %w[running sleeping waking].freeze

  def initialize(app)
    @app = app
    @proxy = Rack::Proxy.new
  end

  def call(env)
    preview = matching_preview(env)
    return @app.call(env) unless preview

    # A visit is an interaction - including one to a sleeping preview, which
    # wakes it.
    root = preview.root
    root.record_interaction!(throttle: true)
    return waking_up(root) unless preview.running?

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
    routable = Preview.where(status: ROUTABLE_STATUSES)
    routable.where(parent_id: nil).find_by(slug: prefix) || routable.find_by(public_hostname: prefix)
  end

  def waking_up(root)
    # Atomically, so that a burst of requests (a page and its assets) only
    # ever queues one wake.
    if Preview.where(id: root.id, status: :sleeping).update_all(status: "waking", updated_at: Time.current) == 1
      PreviewsWakeJob.perform_async(root.id)
    end

    [503,
     { "content-type" => "text/html; charset=utf-8", "retry-after" => "10", "cache-control" => "no-store" },
     [waking_up_page(root.reload)]]
  end

  # Deliberately standalone - no layout or assets - since every request for
  # this hostname, assets included, gets this same response until the
  # preview is back.
  def waking_up_page(root)
    detail = root.status_message.presence || "This usually takes a minute or two."

    <<~HTML
      <!DOCTYPE html>
      <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta http-equiv="refresh" content="10">
          <title>Waking up #{ERB::Util.h(root.slug)}</title>
          <style>body { font-family: arial, sans-serif; margin: 3em auto; max-width: 40em; padding: 0 1em; color: #0b0c0c; }</style>
        </head>
        <body>
          <h1>Waking up this preview…</h1>
          <p>#{ERB::Util.h(root.app_name)} (#{ERB::Util.h(root.branch)}) was put to sleep to make room for other previews.</p>
          <p>#{ERB::Util.h(detail)}</p>
          <p>This page refreshes itself.</p>
        </body>
      </html>
    HTML
  end
end

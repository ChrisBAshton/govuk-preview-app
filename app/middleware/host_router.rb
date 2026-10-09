# Dispatches requests for a running preview's hostname straight to its
# Service in the previews namespace, without ever reaching this app's own routing/auth -
# mirroring the target integration shape (one wildcard entry point -> one
# Preview App process -> internal Host-header dispatch). Requests for
# anything else (the app's own UI, or an unmatched/stale preview subdomain)
# fall through unchanged.
#
# Requires a real Preview App Signon session before proxying to any
# preview - the one gate every preview goes through regardless of the
# previewed app's own code, since not every app has its own login to
# redirect (e.g. Frontend has no gds-sso at all - setting
# GDS_SSO_STRATEGY=real on it, as PreviewEnv does for every app, is a
# no-op if nothing in that app ever calls authenticate_user!). Lives here,
# not in each app, so it can't be missed.
#
# Previews currently live under a *different* domain to Preview App
# itself (see Preview.base_domain's own comment) - no cookie set on
# Preview App's own hostname can ever reach that domain, so this can't
# just check the same session Preview App's own pages use (nor, for the
# same reason, Warden's own env["warden"] - absent here anyway, since
# this runs before Warden::Manager too, see its own initializer). An
# unauthenticated visit is sent to OauthController#continue, which does
# the real Signon round-trip and hands back a short-lived signed token in
# the URL (the one thing that *can* cross that boundary) - #call below
# verifies it and sets its own cookie, scoped to wherever previews
# actually live, so that one round trip covers every preview from then
# on, not just the one that triggered it.
#
# Visiting a preview whose stack has been put to sleep (see PreviewSleeper)
# wakes it, showing a self-refreshing "Waking up" page until it's back.
class HostRouter
  ROUTABLE_STATUSES = %w[running sleeping waking].freeze
  ACCESS_COOKIE = "_govuk_preview_access".freeze

  def initialize(app)
    @app = app
    @proxy = Rack::Proxy.new
  end

  def call(env)
    preview = matching_preview(env)
    return @app.call(env) unless preview
    return not_found unless publicly_allowed?(preview, env)

    request = Rack::Request.new(env)
    token = request.GET["preview_auth"]
    return accept_preview_access(request, token) if token.present? && PreviewSignon.uid_for_preview_access_token(token)
    return redirect_to_login(request) unless authenticated?(request)

    # A visit is an interaction - including one to a sleeping preview, which
    # wakes it.
    root = preview.root
    root.record_interaction!(throttle: true)
    return waking_up(root) unless preview.running?

    env["rack.backend"] = "http://#{KubernetesRunner.new(preview).service_host}"
    @proxy.call(env)
  end

private

  def authenticated?(request)
    PreviewSignon.uid_for_preview_access_token(request.cookies[ACCESS_COOKIE].to_s).present?
  end

  def redirect_to_login(request)
    continue_url = "#{Preview.scheme}://#{Preview.admin_hostname}/oauth/continue?redirect_uri=#{CGI.escape(original_url(request))}"
    [302, { "location" => continue_url, "cache-control" => "no-store" }, []]
  end

  # A freshly minted token (see OauthController#continue), proven valid by
  # the caller already - set it as this domain's own cookie, then redirect
  # to the same URL with the token stripped out, so it doesn't linger in
  # browser history or get sent on in a Referer header.
  def accept_preview_access(request, token)
    headers = { "location" => original_url(request, except: "preview_auth"), "cache-control" => "no-store" }
    Rack::Utils.set_cookie_header!(headers, ACCESS_COOKIE, {
      value: token,
      domain: ".#{Preview.base_domain}",
      path: "/",
      secure: Preview.scheme == "https",
      httponly: true,
      same_site: :lax,
      expires: Time.current + PreviewSignon::PREVIEW_ACCESS_TOKEN_TTL,
    })
    [302, headers, []]
  end

  # Preview.scheme, not request.scheme: the ALB terminates TLS and
  # forwards plain HTTP on to this pod, so the request itself always
  # looks like http:// here regardless of what the browser actually
  # used - same reasoning as Preview#url already uses.
  def original_url(request, except: nil)
    query = request.GET.except(*Array(except))
    query_string = query.empty? ? "" : "?#{URI.encode_www_form(query)}"
    "#{Preview.scheme}://#{request.host_with_port}#{request.path}#{query_string}"
  end

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

  # A publicly readable dependency with `public_paths` (see
  # config/govuk_apps.yml) is only reachable for reading those paths - e.g.
  # Asset Manager serves assets to browsers, but its API, which changes
  # things, must only be reachable from inside the cluster.
  def publicly_allowed?(preview, env)
    paths = GovukApps.find(preview.app_name)&.public_paths
    return true if preview.parent_id.nil? || paths.nil?

    request = Rack::Request.new(env)
    (request.get? || request.head?) && paths.any? { |path| request.path.start_with?(path) }
  end

  def not_found
    [404, { "content-type" => "text/plain; charset=utf-8" }, ["Not found"]]
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

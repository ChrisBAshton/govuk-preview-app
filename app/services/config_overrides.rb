# A fixed initializer, mounted unconditionally into every preview pod's
# config/initializers (see KubernetesRunner#prepare!) - a harmless no-op for
# apps that don't need these fixes, but the only way to fix several classes
# of problem that a plain env var can't, without modifying the app's
# prebuilt image:
#
# - x_sendfile_header: some apps' own production.rb hardcodes this (e.g.
#   Whitehall sets "X-Accel-Redirect", with no env-var override anywhere).
#   Our reverse proxy (HostRouter) has no filesystem access to a preview
#   pod's files at all (different pod), so it can never act on X-Sendfile/
#   X-Accel-Redirect either way - the app has to serve the body itself, and
#   Rack::Sendfile deliberately never reads a runtime header for this
#   (security by design), so the only fix is an initializer overriding the
#   config value - which any file in config/initializers/ can do, since
#   Finisher (where the value is actually read) runs after all of them,
#   regardless of filename.
# - some apps' database.yml has a production block that doesn't reference
#   DATABASE_URL at all (e.g. Whitehall - unlike development/test, which
#   do), so the env var is silently ignored under RAILS_ENV=production.
#   Overriding the connection directly sidesteps whatever database.yml
#   said.
# - some apps' own production.rb sets config.hosts to a real GOV.UK-only
#   allowlist (e.g. Whitehall), so ActionDispatch::HostAuthorization blocks
#   every preview subdomain with a 403 - clearing it removes that check
#   entirely, harmless here since preview subdomains aren't public-facing.
# - Whitehall's "Preview on website"/"View on website" links
#   (Edition#public_url) read GOVUK_WEBSITE_ROOT/PLEK_SERVICE_DRAFT_ORIGIN_URI,
#   not PLEK_SERVICE_FRONTEND_PUBLIC_URL/PLEK_SERVICE_DRAFT_FRONTEND_PUBLIC_URL -
#   and GOVUK_WEBSITE_ROOT is already a fixed baseline env var for every
#   preview (see PreviewEnv), there specifically so
#   Whitehall.integration_or_staging? is true. Overriding it here would
#   silently break that unrelated check, so instead we `prepend` a version
#   of public_url that reads our own already-auto-generated
#   PLEK_SERVICE_FRONTEND_PUBLIC_URL/PLEK_SERVICE_DRAFT_FRONTEND_PUBLIC_URL
#   (see PreviewBuilder#build_dependencies! - deliberately the real,
#   browser-reachable `_PUBLIC_URL`, not the internal, container-only
#   `_URI` also injected there; a link in Whitehall's own HTML needs to be
#   followable by a human's browser, not just by another pod over cluster
#   DNS), falling back to the original implementation
#   (via `super`) whenever neither is set - e.g. because Whitehall has no
#   frontend/draft-frontend dependency declared at all.
#   Wrapped in `to_prepare`, not a bare top-level `defined?(Whitehall)`:
#   config/initializers/*.rb (where this file runs) execute *before*
#   Zeitwerk's autoloader is even set up, so `Whitehall` isn't merely
#   "not loaded yet" at that point, it isn't registered with the
#   autoloader at all - `defined?(Whitehall)` would always be false there.
#   `to_prepare` blocks run after autoloader setup but before eager
#   loading, where the check becomes accurate (and stays correctly false,
#   a no-op, for every other previewed app, which never defines Whitehall).
#   Guards on `defined?(Whitehall)`, not `defined?(Edition)` directly:
#   `defined?` on a not-yet-loaded, autoloadable constant actually forces
#   it to load (a real Ruby/Zeitwerk quirk - it isn't the side-effect-free
#   check it looks like). Publishing API happens to have its own, unrelated
#   `Edition` model too, whose `SymbolizeJSON` concern does schema
#   introspection at class-load time - forcing it to load this way breaks
#   `db:create`/`db:schema:load` (confirmed by direct reproduction: the
#   database doesn't exist yet at that point). `Whitehall` is Whitehall's
#   own plain top-level module (`Whitehall.integration_or_staging?` etc.,
#   already relied on elsewhere in this app) - safe to force-load, and
#   false for every other previewed app, so `Edition` itself is only ever
#   touched when we're actually inside Whitehall.
class ConfigOverrides
  FILENAME = "zzz_preview_app_overrides.rb".freeze

  def self.content
    <<~RUBY
      Rails.application.config.action_dispatch.x_sendfile_header = nil
      ActiveRecord::Base.establish_connection(ENV["DATABASE_URL"]) if ENV["DATABASE_URL"]
      Rails.application.config.hosts.clear

      Rails.application.config.to_prepare do
        if defined?(Whitehall) && defined?(Edition)
          Edition.prepend(Module.new do
            def public_url(options = {})
              return if base_path.nil?

              env_key = options[:draft] ? "PLEK_SERVICE_DRAFT_FRONTEND_PUBLIC_URL" : "PLEK_SERVICE_FRONTEND_PUBLIC_URL"
              website_root = ENV[env_key]
              return super if website_root.blank?

              website_root + public_path(options)
            end
          end)
        end
      end
    RUBY
  end
end

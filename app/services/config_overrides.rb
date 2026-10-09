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
#   So the connection is re-established from DATABASE_URL - but on top of
#   everything else the app's own production config says, minus only its
#   connection details. Those other settings matter: e.g. Whitehall's
#   `variables: { sql_mode: TRADITIONAL }` turns off MySQL 8's default
#   ONLY_FULL_GROUP_BY, which some of its queries rely on, and sets its
#   encoding to utf8mb4.
# - some apps' own production.rb sets config.hosts to a real GOV.UK-only
#   allowlist (e.g. Whitehall), so ActionDispatch::HostAuthorization blocks
#   every preview subdomain with a 403 - clearing it removes that check
#   entirely, harmless here since preview subdomains aren't public-facing.
# - apps' Content Security Policies (e.g. Frontend's, from govuk_app_config)
#   only allow images from real GOV.UK hosts - so a page couldn't show an
#   image from its stack's own Asset Manager, at a preview hostname. Every
#   preview's hostname is added to img-src, for apps that have a policy at
#   all. (Locally, `*.dev.gov.uk` doesn't cover them either: a source with
#   no port only matches the scheme's default one, and previews are on
#   :8080.) Frontend sets its policy in an initializer of its own, which
#   runs before this one.
# - gds-sso apps also validate *API* bearer tokens for real under
#   GDS_SSO_STRATEGY=real (PreviewEnv sets this on every app, for
#   HostRouter's benefit - see its own comment) - by calling back to this
#   same PreviewSignon-backed /user.json, which only ever recognises a
#   token issued through its own OAuth2 exchange. So a server-to-server
#   call between two previews with any other bearer token (e.g.
#   Whitehall's own, calling Publishing API's API) gets rejected, even
#   though that call never goes near HostRouter or the internet at all -
#   it's cluster-internal, already walled off by NetworkPolicy. Forcing
#   Warden::OAuth2 back to gds-sso's own mock token model (accepts any
#   token as a trusted dummy API user) restores that, independently of
#   the real strategy still gating actual browser logins.
class ConfigOverrides
  FILENAME = "zzz_preview_app_overrides.rb".freeze

  def self.content
    <<~RUBY
      Rails.application.config.action_dispatch.x_sendfile_header = nil
      if ENV["DATABASE_URL"]
        app_config = ActiveRecord::Base.configurations.configs_for(env_name: Rails.env).first&.configuration_hash || {}
        ActiveRecord::Base.establish_connection(
          app_config.except(:url, :database, :username, :password, :host, :port, :socket).merge(url: ENV["DATABASE_URL"]),
        )
      end
      Rails.application.config.hosts.clear
      # Through #directives: a directive's own method (e.g. img_src) with no
      # arguments deletes it.
      if (policy = Rails.application.config.content_security_policy) && policy.directives["img-src"]
        policy.directives["img-src"] += [#{Preview.csp_source.inspect}]
      end
      if defined?(Warden::OAuth2) && defined?(GDS::SSO::MockBearerToken)
        Warden::OAuth2.config.token_model = GDS::SSO::MockBearerToken
      end
    RUBY
  end
end

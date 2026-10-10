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
# - Warden::OAuth2's token_model governs API bearer-token calls between
#   previews (e.g. Whitehall's own, calling Publishing API's API) -
#   forcing it to gds-sso's own mock model (accepts any token as a
#   trusted dummy API user) keeps those working regardless of whatever
#   GDS_SSO_STRATEGY resolves to for any given app (PreviewEnv currently
#   sets "mock" on every one, which already implies this on its own -
#   but a previewed app's own gds-sso strategy and its API bearer-token
#   handling aren't actually tied together, so this stays explicit
#   rather than relying on that happening to line up).
# - that same mock token model's one dummy API user (gds-sso's
#   GDS::SSO::MockBearerToken) is found-or-created by a plain, unindexed
#   email lookup, with no protection against two concurrent first-ever API
#   calls both creating one - so two apps' own dummy users (e.g. Whitehall's
#   worker and Asset Manager's own) aren't guaranteed to end up being the
#   *same* row every time, even though every mock API call is conceptually
#   "trusted". Asset Manager's own authorization falls back to an explicit
#   permission when an asset's owner isn't literally the same row as the
#   caller (Asset#manageable_by?) - otherwise rejecting Whitehall's own
#   later read-back of an asset it just created itself, under a
#   differently-looked-up dummy user, as a 403. Granting every previewed
#   app's dummy user that permission sidesteps the ambiguity entirely,
#   rather than fixing gds-sso's own race.
# - Asset Manager's own MediaController requires a real Signon session to
#   read a draft asset (e.g. a lead image still being edited in Whitehall),
#   on top of HostRouter's own gate - rendering several on one page used
#   to mean several concurrent OAuth round trips racing each other, with
#   some arriving out of order and failing. Reachable only at an
#   unguessable preview hostname already, with nothing sensitive ever
#   going through it, a preview's own Asset Manager doesn't need that
#   second gate at all - so GET/HEAD requests (the only verbs its own
#   media-serving routes ever accept) skip it entirely.
# - that same MediaController also can't tell a request from another
#   preview's own pod (e.g. Whitehall's worker, reading an asset's file back
#   to build a cropped thumbnail) apart from a real browser's: it compares
#   the request's Host header against Plek.find("asset-manager") - which,
#   evaluated from inside Asset Manager's own pod (nothing ever points
#   Asset Manager at itself the way PreviewBuilder points everything
#   *else* at it), just falls back to the real asset-manager.www.gov.uk.
#   So it always redirects such a request to its own public hostname
#   instead of serving it directly - fine for a browser, useless for
#   another pod, which can never reach a preview's public hostname at all
#   (that only resolves - and only on its external port - outside the
#   cluster). Recognising PREVIEW_APP_INTERNAL_URL (see PreviewEnv) as its
#   own internal host fixes that for every caller of
#   requested_from_internal_host?, including the one case it still left
#   broken even once recognised: it serves a real asset by redirecting to
#   its own fake-S3 file at its public hostname (self_url_env's
#   FAKE_S3_HOST) - also unreachable from another pod - so an internal
#   caller is redirected there via PREVIEW_APP_INTERNAL_URL instead.
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
      if defined?(GDS::SSO::Config)
        GDS::SSO::Config.additional_mock_permissions_required = ["Manage all Assets"]
      end
      # config/initializers/* run before Rails eager-loads the app's own
      # classes (that happens in the Finisher, afterwards) - so a bare
      # `if defined?(MediaController)` here is always false in production,
      # silently skipping this entirely. to_prepare runs once that's done,
      # the standard hook for patching an autoloaded class from outside it.
      Rails.application.config.to_prepare do
        if defined?(MediaController)
          MediaController.class_eval do
            protected

            def authorized_for_asset?(_asset) = true

            def redirect_to_draft_assets_host_for?(_asset) = false

            def requested_from_internal_host?
              request.host == URI.parse(ENV.fetch("PREVIEW_APP_INTERNAL_URL")).host
            end

            def proxy_to_s3_via_nginx(asset)
              headers["ETag"] = %("\#{asset.etag}")
              headers["Last-Modified"] = asset.last_modified.httpdate
              headers["Content-Disposition"] = AssetManager.content_disposition.header_for(asset)

              if request.fresh?(response)
                head :not_modified
              elsif AssetManager.s3.fake?
                url = Services.cloud_storage.presigned_url_for(asset, http_method: request.request_method)
                url = ENV.fetch("PREVIEW_APP_INTERNAL_URL") + URI.parse(url).path if requested_from_internal_host?
                redirect_to url
              else
                url = Services.cloud_storage.presigned_url_for(asset, http_method: request.request_method)
                headers["X-Accel-Redirect"] = "/cloud-storage-proxy/\#{url}"
                head :ok, content_type: content_type(asset)
              end
            end
          end
        end
      end
    RUBY
  end
end

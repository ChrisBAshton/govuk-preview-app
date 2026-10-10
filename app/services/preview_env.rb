require "securerandom"

# The env vars every preview pod gets.
#
# SECRET_KEY_BASE is needed for any Rails app to boot at all in production
# mode (which the base GOV.UK Docker images run in by default) - it's not
# app-specific, so every preview container gets its own random one.
# RAILS_SERVE_STATIC_FILES: in real production, static assets are served by
# a separate layer (CDN/asset host), not Rails itself - most GOV.UK apps'
# own production.rb gates config.public_file_server.enabled on this env var
# (a few, e.g. Whitehall, always enable it regardless, in which case this
# is simply a no-op). There's no separate asset-serving layer here, so
# every preview needs Rails to serve its own assets directly.
# GDS_SSO_STRATEGY=mock: gds-sso's own mock auth, signing straight in as
# the first/a seeded user in the previewed app's own local DB - no OAuth2
# round trip, no network call out of this pod at all. A real OAuth2
# Authorization Code + PKCE exchange against Preview App's own
# OauthController (see PreviewSignon) was tried instead, so a preview
# carried through the specific person's own real Signon identity rather
# than a generic seeded user - but it needs the previewed app's own pod
# to call back to Preview App itself over the network, which never
# reliably worked locally (the admin hostname only resolves at all
# because of a developer's own dnsmasq rule, which pods don't go
# through), and turned out not to be worth it: HostRouter's own
# `_govuk_preview_access` cookie gate (added separately, independent of
# this setting entirely) already requires a real Preview App Signon
# login before any request reaches any preview's pod at all, regardless
# of the previewed app's own auth mode - which was the actual goal.
# REDIS_URL: govuk_sidekiq's railtie eagerly connects to Redis at boot for
# *any* rake task, not just when a worker actually runs - so any app using
# that gem (most GOV.UK admin apps) needs a reachable Redis just to boot.
# Each stack has its own, with a database per app - see StackRedis.
# GOVUK_ENVIRONMENT: the standard variable every GOV.UK app on Kubernetes
# gets, saying which environment it's in (govuk_app_config's
# GovukEnvironment.current) - previews behave as integration, so e.g.
# Whitehall's integration-only features and /flipflop dashboard are on.
# GOVUK_WEBSITE_ROOT: where an app's public links point (Plek.website_root)
# - the real integration site by default. An app whose stack runs its own
# Frontend can point its links there instead, via the manifest's
# `env_aliases` (see Whitehall's in config/govuk_apps.yml). Older versions
# of some apps (e.g. Whitehall, before it read GOVUK_ENVIRONMENT) also
# guessed their environment from this containing "integration".
# GOVUK_ASSET_ROOT: another standard Plek/GOV.UK env var - many publishing
# apps resolve it at boot (e.g. Publisher's SafeHtml validator), and Plek
# raises if it's unset in production.
# WEB_CONCURRENCY/RAILS_MAX_THREADS (web pods only): every previewed app
# configures Puma through govuk_app_config's GovukPuma, which by default
# forks 2 worker processes - a full extra copy of the app each - with 5
# threads apiece. A preview serves a handful of people, so one process (0
# means Puma's single mode, no forking) with a few threads is plenty, for
# a fraction of the memory. Not set for worker/task pods: Sidekiq sizes its
# database pool from RAILS_MAX_THREADS too (see KubernetesRunner).
# Each app's manifest entry can also name env vars to set to the preview's
# own public URL (`self_url_env`) - e.g. Asset Manager's asset hosts, which
# it uses both to build asset URLs and to recognise requests for itself.
# Beyond these, each app's manifest entry can declare a fixed set of extra
# env vars (e.g. pointing an app's Plek-resolved dependencies at real
# GOV.UK services), and `extra_env` carries per-instance values resolved
# at build time (a dependency's own PLEK_SERVICE_*_URI, DATABASE_URL) that
# can't live in the static manifest - see config/govuk_apps.yml.
module PreviewEnv
  WEB_SERVER_ENV = { "WEB_CONCURRENCY" => "0", "RAILS_MAX_THREADS" => "3" }.freeze

  def self.for(preview, extra_env = {}, web: false)
    app = GovukApps.find(preview.app_name)

    {
      app.port_env_var => KubernetesRunner::APP_PORT,
      "SECRET_KEY_BASE" => SecureRandom.hex(32),
      "RAILS_SERVE_STATIC_FILES" => "true",
      "GDS_SSO_STRATEGY" => "mock",
      # Not a GOV.UK/Plek convention any app's own code reads - only
      # ConfigOverrides does, for the rare case (e.g. Asset Manager's own
      # MediaController) where an app needs to tell a request aimed at its
      # own pod (PreviewBuilder#build_dependencies!'s PLEK_SERVICE_*_URI,
      # the same address every *other* app reaches it at) apart from one
      # aimed at its preview's public hostname - Plek.find(app_name) from
      # inside an app's own pod just falls back to its real GOV.UK address,
      # never this one.
      "PREVIEW_APP_INTERNAL_URL" => "http://#{KubernetesRunner.new(preview).container_name}",
      "REDIS_URL" => StackRedis.url_for(preview),
      "GOVUK_ENVIRONMENT" => "integration",
      "GOVUK_WEBSITE_ROOT" => "https://www.integration.publishing.service.gov.uk",
      "GOVUK_ASSET_ROOT" => "https://assets.integration.publishing.service.gov.uk",
      **(web ? WEB_SERVER_ENV : {}),
    }.merge(app.env).merge(app.self_url_env.index_with { preview.url }).merge(extra_env).transform_values(&:to_s)
  end

  # A failing `bin/rails` invocation's output is usually preceded by
  # unrelated boilerplate (a container home-directory warning, Bundler's
  # tmpdir notice) - callers that truncate this (e.g. PreviewBuilder's
  # status_message) would otherwise keep only that noise and lose the
  # actual error. Start from "bin/rails aborted!" when present; anything
  # else (no such marker) falls back to the raw text.
  def self.relevant_error(output)
    marker = output.index("bin/rails aborted!")
    marker ? output[marker..] : output
  end
end

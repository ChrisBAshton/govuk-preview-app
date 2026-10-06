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
# GDS_SSO_STRATEGY: forces gds-sso's mock auth strategy regardless of
# RAILS_ENV (verified working for Preview App's own gds-sso setup, and for
# Whitehall/Publishing API's) - harmless for apps that don't use gds-sso.
# REDIS_URL: govuk_sidekiq's railtie eagerly connects to Redis at boot for
# *any* rake task, not just when a worker actually runs - so any app using
# that gem (most GOV.UK admin apps) needs a reachable Redis just to boot.
# Every preview shares one Redis, the `redis` Service in the previews
# namespace (see kubernetes/previews/redis.yaml).
# GOVUK_WEBSITE_ROOT: a standard Plek/GOV.UK env var (not app-specific) -
# some apps gate integration/staging-only behaviour on it containing
# "integration"/"staging" (e.g. Whitehall's /flipflop dashboard access
# filter, Whitehall.integration_or_staging?) - previews are integration-
# like environments, so this makes that recognised rather than silently
# blocked under RAILS_ENV=production.
# WEB_CONCURRENCY/RAILS_MAX_THREADS (web pods only): every previewed app
# configures Puma through govuk_app_config's GovukPuma, which by default
# forks 2 worker processes - a full extra copy of the app each - with 5
# threads apiece. A preview serves a handful of people, so one process (0
# means Puma's single mode, no forking) with a few threads is plenty, for
# a fraction of the memory. Not set for worker/task pods: Sidekiq sizes its
# database pool from RAILS_MAX_THREADS too (see KubernetesRunner).
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
      "REDIS_URL" => "redis://redis:6379",
      "GOVUK_WEBSITE_ROOT" => "https://www.integration.publishing.service.gov.uk",
      **(web ? WEB_SERVER_ENV : {}),
    }.merge(app.env).merge(extra_env).transform_values(&:to_s)
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

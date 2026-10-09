# Widened to cover every preview subdomain, not just this app's own
# hostname - so the same session (and therefore the same real Signon
# login) carries over when HostRouter sends a browser off to log in and
# back (see HostRouter and OauthController#continue). Defaults to the
# local dev domain, like PREVIEW_APP_BASE_DOMAIN itself - plain ENV read,
# not Preview.admin_hostname, since this runs too early in Rails' boot for
# autoloading to resolve app/models yet (see config/environments'
# own comment on the same thing).
admin_hostname = ENV.fetch("PREVIEW_APP_BASE_DOMAIN", "govuk-preview-app.dev.gov.uk")
Rails.application.config.session_store :cookie_store, key: "_govuk_preview_app_session", domain: ".#{admin_hostname}"

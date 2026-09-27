# Writes a fixed file into a checkout, unconditionally, before it's built -
# a harmless no-op for apps that don't need either fix, but the only way to
# fix two classes of problem that a plain `docker run -e ...` env var can't:
#
# - x_sendfile_header: some apps' own production.rb hardcodes this (e.g.
#   Whitehall sets "X-Accel-Redirect", with no env-var override anywhere).
#   Our reverse proxy has no filesystem access to a preview container's
#   files at all (different container), so it can never act on X-Sendfile/
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
class ConfigOverrides
  def initialize(checkout_path)
    @checkout_path = checkout_path
  end

  def write!
    path = checkout_path.join("config/initializers/zzz_app_preview_overrides.rb")
    FileUtils.mkdir_p(path.dirname)
    File.write(path, <<~RUBY)
      Rails.application.config.action_dispatch.x_sendfile_header = nil
      ActiveRecord::Base.establish_connection(ENV["DATABASE_URL"]) if ENV["DATABASE_URL"]
      Rails.application.config.hosts.clear
    RUBY
  end

private

  attr_reader :checkout_path
end

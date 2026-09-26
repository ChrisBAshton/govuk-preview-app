# Dispatches requests for a running preview's hostname straight to its
# sibling container, without ever reaching this app's own routing/auth -
# mirroring the target integration shape (one wildcard entry point -> one
# App Preview process -> internal Host-header dispatch). Requests for
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

    env["rack.backend"] = "http://#{DockerRunner.new(preview).container_name}:#{preview.port}"
    @proxy.call(env)
  end

private

  def matching_preview(env)
    host = Rack::Request.new(env).host
    suffix = ".#{Preview.base_domain}"
    return nil unless host.end_with?(suffix)

    Preview.running.find_by(slug: host.delete_suffix(suffix))
  end
end

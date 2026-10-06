require "json"
require "net/http"

# Finds the prebuilt image for an app at a given branch - the Kubernetes
# runtime's replacement for Checkout + `docker build` (see PreviewRuntime).
# Nothing is built in-cluster: building needs either a privileged Docker
# daemon or a builder that breaks the `restricted` Pod Security standard,
# and the result would have to be pushed to a registry anyway, since
# Kubernetes nodes only ever run images they can pull.
#
# Instead it relies on images GOV.UK's own GitHub Actions already push to
# GHCR:
# - `main` - every release is built and pushed by the app's own deploy.yml,
#   tagged with its release tag (e.g. v1234). We use the latest release, so
#   a dependency always runs whatever's currently on integration.
# - any other branch - the app's "Build image from PR" workflow, with
#   pushing enabled, pushes every PR commit tagged with its full SHA. We
#   take the branch's current head commit and wait for that image to
#   appear, since a just-pushed branch's build may still be running.
class ImageResolver
  class ImageError < StandardError; end

  GITHUB_API = "https://api.github.com".freeze
  GHCR = "ghcr.io".freeze
  GHCR_NAMESPACE = "alphagov/govuk".freeze
  POLL_INTERVAL = 30

  attr_reader :app, :branch

  def initialize(app, branch)
    @app = app
    @branch = branch
  end

  # Returns a full image reference to run, e.g.
  # "<registry>/whitehall:3f2c...". The registry defaults to GHCR itself,
  # but on integration it points at the ECR pull-through cache in front of
  # it - the same one every real GOV.UK app's image is pulled through.
  def resolve!
    tag = branch == "main" ? latest_release_tag : head_sha
    wait_until_published!(tag)
    "#{registry}/#{image_name}:#{tag}"
  end

  def image_name
    File.basename(URI.parse(app.repo_url).path, ".git")
  end

private

  def registry
    ENV.fetch("PREVIEW_APP_IMAGE_REGISTRY", "#{GHCR}/#{GHCR_NAMESPACE}")
  end

  def repo_path
    URI.parse(app.repo_url).path.delete_prefix("/").delete_suffix(".git")
  end

  def latest_release_tag
    github_get("/repos/#{repo_path}/releases/latest").fetch("tag_name")
  end

  def head_sha
    github_get("/repos/#{repo_path}/commits/#{ERB::Util.url_encode(branch)}").fetch("sha")
  end

  def github_get(path)
    uri = URI("#{GITHUB_API}#{path}")
    req = Net::HTTP::Get.new(uri)
    req["Accept"] = "application/vnd.github+json"
    # Optional - only to lift the unauthenticated rate limit (60 requests
    # an hour); every repo we read is public.
    token = ENV["PREVIEW_APP_GITHUB_TOKEN"]
    req["Authorization"] = "Bearer #{token}" if token.present?

    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |http| http.request(req) }
    raise ImageError, "Couldn't find #{branch.inspect} in #{repo_path} on GitHub" if response.code == "404"
    raise ImageError, "GitHub API error (#{response.code}) for #{path}" unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body)
  end

  def wait_until_published!(tag)
    deadline = Time.current + wait_timeout

    until published?(tag)
      if Time.current > deadline
        raise ImageError,
              "No image #{GHCR}/#{GHCR_NAMESPACE}/#{image_name}:#{tag} was published within #{wait_timeout / 60} " \
              "minutes - check the \"Build image from PR\" workflow ran on this branch in #{repo_path}"
      end

      pause
    end
  end

  # Always checked against GHCR itself, even when pods pull through ECR:
  # a pull-through cache only knows about an image once something has
  # already pulled it.
  def published?(tag)
    uri = URI("https://#{GHCR}/v2/#{GHCR_NAMESPACE}/#{image_name}/manifests/#{tag}")
    req = Net::HTTP::Head.new(uri)
    req["Authorization"] = "Bearer #{ghcr_token}"
    req["Accept"] = [
      "application/vnd.oci.image.index.v1+json",
      "application/vnd.oci.image.manifest.v1+json",
      "application/vnd.docker.distribution.manifest.list.v2+json",
      "application/vnd.docker.distribution.manifest.v2+json",
    ].join(", ")

    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |http| http.request(req) }
    response.is_a?(Net::HTTPSuccess)
  end

  # GHCR wants a bearer token even for anonymous pulls of public images.
  def ghcr_token
    uri = URI("https://#{GHCR}/token?scope=repository:#{GHCR_NAMESPACE}/#{image_name}:pull")
    JSON.parse(Net::HTTP.get(uri)).fetch("token")
  end

  def wait_timeout
    ENV.fetch("PREVIEW_APP_IMAGE_WAIT_SECONDS", 1800).to_i
  end

  def pause
    sleep POLL_INTERVAL
  end
end

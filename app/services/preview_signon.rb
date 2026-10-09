require "redis_client"
require "securerandom"
require "digest"
require "base64"

# govuk-preview-app acting as its own minimal Signon stand-in for every
# previewed app (see OauthController), replacing the old GDS_SSO_STRATEGY
# of "mock" previews ran under - which authenticated *any* visitor as a
# seeded test user, no login at all. A random person who found a preview's
# URL could sign in as a full admin and start editing/publishing.
#
# Now a previewed app's real gds-sso strategy is pointed at this host
# instead of the real Signon (see PreviewEnv's PLEK_SERVICE_SIGNON_URI),
# and goes through an actual OAuth2 Authorization Code + PKCE exchange -
# but "logging in" is just reusing whichever real Signon session already
# authenticated someone to Preview App itself (OauthController#authorize
# requires that, via ApplicationController's own authenticate_user!), with
# no separate consent screen - mirroring the same no-consent trust real
# Signon extends to first-party GOV.UK apps (see its
# config/initializers/doorkeeper.rb).
#
# client_id is simply the previewed app's name (e.g. "whitehall") - there's
# no need for a registry of per-app OAuth clients, since both sides of this
# exchange are our own code. CLIENT_SECRET exists only because gds-sso's
# OAuth2 client requires one to be configured - it isn't a meaningful
# access boundary (that's the real Signon session check above, and
# #valid_redirect_uri? below).
module PreviewSignon
  CLIENT_SECRET = "preview-app-oauth-shared-secret-not-sensitive".freeze
  CODE_TTL = 60 # seconds - a code only has to survive one redirect round trip.
  TOKEN_TTL = 1.day.to_i

  AuthorizationError = Class.new(StandardError)

  def self.redis
    # Same default as govuk_sidekiq's own railtie - CI's setup-redis action
    # just starts one on this port, with no REDIS_URL of its own.
    @redis ||= RedisClient.new(url: ENV.fetch("REDIS_URL", "redis://127.0.0.1:6379"))
  end

  # Only true for a real, currently-running preview's own gds-sso callback
  # URL - the fixed path gds-sso's real OAuth2 strategy always uses, never
  # an arbitrary page. See #valid_preview_url? for the looser check used
  # to send a browser back to wherever it actually asked for.
  def self.valid_redirect_uri?(redirect_uri)
    valid_preview_url?(redirect_uri) { |uri| uri.path == "/auth/gds/callback" }
  end

  # True for any URL under a real, currently-running preview's own
  # hostname - the same universe HostRouter would otherwise proxy a
  # request to, never an arbitrary external URL. Scoped to an actual
  # running Preview (not just "any subdomain of ours") as defence in
  # depth, reusing the same lookup HostRouter itself uses to route a
  # request. Used by OauthController#continue to return a browser to
  # whichever page of a preview it was actually trying to reach.
  def self.valid_preview_url?(url)
    uri = URI.parse(url)
    return false unless uri.scheme == Preview.scheme
    return false unless uri.host&.end_with?(".#{Preview.base_domain}")
    return false if block_given? && !yield(uri)

    prefix = uri.host.delete_suffix(".#{Preview.base_domain}")
    routable = Preview.where(status: HostRouter::ROUTABLE_STATUSES)
    routable.where(parent_id: nil).exists?(slug: prefix) || routable.exists?(public_hostname: prefix)
  rescue URI::InvalidURIError
    false
  end

  # Issues a short-lived, single-use authorization code for `user`, bound
  # to this one client/redirect_uri/code_challenge.
  def self.issue_code(user:, client_id:, redirect_uri:, code_challenge:)
    code = SecureRandom.urlsafe_base64(32)
    redis.call("SET", "code:#{code}", payload_for(user, client_id, redirect_uri, code_challenge).to_json, "EX", CODE_TTL)
    code
  end

  # Redeems a code exactly once: checks it's unexpired, bound to this same
  # client/redirect_uri, and that `code_verifier` actually hashes to the
  # code_challenge presented when the code was issued (PKCE) - then issues
  # an access token carrying the same user details.
  def self.exchange_code(code:, client_id:, redirect_uri:, code_verifier:)
    raw = redis.call("GET", "code:#{code}")
    raise AuthorizationError, "unknown or expired code" unless raw

    redis.call("DEL", "code:#{code}")
    data = JSON.parse(raw)
    raise AuthorizationError, "client_id mismatch" unless data["client_id"] == client_id
    raise AuthorizationError, "redirect_uri mismatch" unless data["redirect_uri"] == redirect_uri
    raise AuthorizationError, "code_verifier mismatch" unless challenge_for(code_verifier) == data["code_challenge"]

    token = SecureRandom.urlsafe_base64(32)
    redis.call("SET", "token:#{token}", data["user"].to_json, "EX", TOKEN_TTL)
    token
  end

  def self.user_for_token(token)
    raw = redis.call("GET", "token:#{token}")
    raw && JSON.parse(raw)
  end

  # Handing a browser proof of a real Preview App login across to the
  # (temporarily, see Preview.base_domain's own comment) *different*
  # domain previews live under - a signed cookie set on Preview App's own
  # hostname can never be sent there at all (no common suffix to share,
  # never mind scoping it wider), so this has to travel some other way.
  # Stateless (Rails' own message_verifier, not Redis): nothing else here
  # needs to invalidate a specific one early, and it only ever has to
  # outlive one redirect round trip, so there's no reason to add a store
  # for it. See HostRouter, where this is both issued-for and verified.
  PREVIEW_ACCESS_TOKEN_TTL = 1.day

  def self.issue_preview_access_token(user)
    message_verifier.generate({ "uid" => user.uid }, expires_in: PREVIEW_ACCESS_TOKEN_TTL)
  end

  # The uid alone, not a full user payload like #user_for_token - this
  # only ever answers "is this a real, currently valid Preview App login",
  # the same yes/no HostRouter would otherwise get from env["warden"].
  def self.uid_for_preview_access_token(token)
    message_verifier.verify(token)["uid"]
  rescue ActiveSupport::MessageVerifier::InvalidSignature
    nil
  end

  def self.message_verifier
    Rails.application.message_verifier(:preview_access)
  end
  private_class_method :message_verifier

  def self.challenge_for(verifier)
    Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)
  end

  def self.payload_for(user, client_id, redirect_uri, code_challenge)
    {
      "client_id" => client_id,
      "redirect_uri" => redirect_uri,
      "code_challenge" => code_challenge,
      "user" => {
        "uid" => user.uid,
        "name" => user.name,
        "email" => user.email,
        "permissions" => GovukApps.find(client_id)&.signon_permissions || %w[signin],
        "organisation_slug" => user.organisation_slug,
        "organisation_content_id" => user.organisation_content_id,
        "disabled" => false,
      },
    }
  end
  private_class_method :payload_for
end

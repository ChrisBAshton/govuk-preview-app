# govuk-preview-app acting as its own minimal Signon stand-in - see
# OauthController#continue, the one gate every preview goes through (via
# HostRouter), regardless of the previewed app's own code.
module PreviewSignon
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

    prefix = uri.host.delete_suffix(".#{Preview.base_domain}")
    routable = Preview.where(status: HostRouter::ROUTABLE_STATUSES)
    routable.where(parent_id: nil).exists?(slug: prefix) || routable.exists?(public_hostname: prefix)
  rescue URI::InvalidURIError
    false
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

  # The uid alone - this only ever answers "is this a real, currently
  # valid Preview App login", the same yes/no HostRouter would otherwise
  # get from env["warden"].
  def self.uid_for_preview_access_token(token)
    message_verifier.verify(token)["uid"]
  rescue ActiveSupport::MessageVerifier::InvalidSignature
    nil
  end

  def self.message_verifier
    Rails.application.message_verifier(:preview_access)
  end
  private_class_method :message_verifier
end

# The server-to-server half of standing in for Signon - see
# OauthController for the browser-facing /oauth/authorize redirect, and
# PreviewSignon for the design rationale and the actual code/token logic.
#
# ActionController::API, not ApplicationController: these two calls come
# from a previewed app's own Rails process (the oauth2 gem, via gds-sso),
# never a browser - there's no session/cookie to forge, so this simply
# never has CSRF protection to disable, rather than disabling it.
class OauthTokensController < ActionController::API
  # Warden::Manager wraps the whole app as Rack middleware, regardless of
  # which controller class handles a request - without this, a 401 from
  # either action below would be intercepted by its intercept_401 config
  # and turned into a redirect to /auth/gds, not the JSON error response
  # gds-sso's OAuth2 client actually expects.
  before_action -> { request.env["gds_sso.api_call"] = true }

  # POST /oauth/access_token - authenticated by HTTP Basic auth
  # (client_id/client_secret), not a session.
  def token
    client_id, client_secret = ActionController::HttpAuthentication::Basic.decode_credentials(request).split(":", 2)
    unless client_secret == PreviewSignon::CLIENT_SECRET
      render json: { error: "invalid_client" }, status: :unauthorized
      return
    end

    access_token = PreviewSignon.exchange_code(
      code: params[:code],
      client_id: client_id,
      redirect_uri: params[:redirect_uri],
      code_verifier: params[:code_verifier],
    )
    render json: { access_token: access_token, token_type: "bearer" }
  rescue PreviewSignon::AuthorizationError => e
    # The oauth2 gem (gds-sso's own HTTP client) only ever raises a
    # generic OAuth2::Error on any non-2xx response, which OmniAuth then
    # reports to the browser as a bare "invalid_credentials" - this is
    # the only place the real reason (which check in
    # PreviewSignon.exchange_code failed) is still visible at all.
    Rails.logger.warn("OauthTokensController#token: #{e.message} (client_id=#{client_id.inspect}, redirect_uri=#{params[:redirect_uri].inspect})")
    render json: { error: "invalid_grant", error_description: e.message }, status: :bad_request
  end

  # GET /user.json?client_id=... - bearer-token authenticated (see
  # gds-sso's OmniAuth::Strategies::Gds#user).
  def user_info
    token = request.authorization.to_s[/\ABearer (.+)\z/, 1]
    user = token && PreviewSignon.user_for_token(token)
    unless user
      render json: { error: "invalid_token" }, status: :unauthorized
      return
    end

    render json: { user: user }
  end
end

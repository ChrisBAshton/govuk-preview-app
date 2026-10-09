# The 3 endpoints gds-sso's real OAuth2 strategy needs, standing in for
# Signon itself - see PreviewSignon for the design rationale and the
# actual code/token logic; this controller is just the HTTP layer.
class OauthController < ApplicationController
  skip_before_action :authenticate_user!, only: %i[token user_info]
  skip_before_action :verify_authenticity_token, only: %i[token], raise: false
  # Neither action has a browser session to redirect from - without this,
  # Warden's intercept_401 (GDS::SSO::Config.intercept_401_responses)
  # would catch a 401 from either action and turn it into a redirect to
  # /auth/gds instead of the JSON error response gds-sso's OAuth2 client
  # actually expects.
  before_action -> { request.env["gds_sso.api_call"] = true }, only: %i[token user_info]

  # GET /oauth/authorize - only ever reached after a real Signon login:
  # ApplicationController's own authenticate_user! (still active here)
  # redirects an unauthenticated visit through gds-sso's real sign-in
  # first, landing back on this same URL (query string and all) once
  # signed in - so by the time we get here, current_user is a real,
  # Signon-authenticated Preview App user. No separate consent screen,
  # mirroring Signon's own trust of first-party GOV.UK apps.
  def authorize
    unless GovukApps.app_names.include?(params[:client_id]) &&
        PreviewSignon.valid_redirect_uri?(params[:redirect_uri]) &&
        params[:code_challenge_method] == "S256" && params[:code_challenge].present?
      render plain: "Invalid OAuth authorize request", status: :bad_request
      return
    end

    code = PreviewSignon.issue_code(
      user: current_user,
      client_id: params[:client_id],
      redirect_uri: params[:redirect_uri],
      code_challenge: params[:code_challenge],
    )
    redirect_to "#{params[:redirect_uri]}?code=#{code}&state=#{CGI.escape(params[:state].to_s)}", allow_other_host: true
  end

  # POST /oauth/access_token - a server-to-server call from inside a
  # previewed app's own pod (the oauth2 gem, driven by gds-sso) - there's
  # no browser session here, so this authenticates the caller by HTTP
  # Basic auth (client_id/client_secret) instead.
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
    render json: { error: "invalid_grant", error_description: e.message }, status: :bad_request
  end

  # GET /user.json?client_id=... - another server-to-server call, bearer-
  # token authenticated (see gds-sso's OmniAuth::Strategies::Gds#user).
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

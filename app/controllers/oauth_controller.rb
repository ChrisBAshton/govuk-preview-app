# The browser-facing half of standing in for Signon - see
# OauthTokensController for the server-to-server half, and PreviewSignon
# for the design rationale and the actual code/token logic.
class OauthController < ApplicationController
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
end

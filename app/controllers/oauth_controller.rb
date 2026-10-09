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

  # GET /oauth/continue - where HostRouter sends a browser that reached a
  # preview with no active Preview App session (see its own comment on
  # why that check lives there, not in each previewed app) - every
  # previewed app gets this, including ones with no login of their own
  # (e.g. Frontend), unlike #authorize above, which only real gds-sso
  # apps ever hit. authenticate_user! (still active here) does the actual
  # work: redirects through a real Signon login first if needed, landing
  # back on this same URL once signed in - so by the time we get here,
  # current_user is a real, Signon-authenticated Preview App user.
  #
  # Previews currently live under a *different* domain to Preview App
  # itself (see Preview.base_domain's own comment), so there's no cookie
  # that could already cover redirect_uri the way there would be if they
  # shared one - a signed, short-lived token travelling in the URL itself
  # is what proves the login across that boundary. HostRouter verifies it
  # and sets its own cookie, scoped to wherever previews actually live,
  # so this round trip only has to happen once.
  def continue
    unless PreviewSignon.valid_preview_url?(params[:redirect_uri])
      render plain: "Invalid redirect_uri", status: :bad_request
      return
    end

    # CGI.escape, not raw interpolation: the token is standard (not
    # urlsafe) base64, which can contain + and / - embedded unescaped, a
    # literal "+" would come back as a space once Rack parses the query
    # string on the other end, silently corrupting it.
    token = CGI.escape(PreviewSignon.issue_preview_access_token(current_user))
    separator = params[:redirect_uri].include?("?") ? "&" : "?"
    redirect_to "#{params[:redirect_uri]}#{separator}preview_auth=#{token}", allow_other_host: true
  end
end

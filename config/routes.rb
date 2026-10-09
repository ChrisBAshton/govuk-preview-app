Rails.application.routes.draw do
  get "/healthcheck/live", to: proc { [200, {}, %w[OK]] }
  get "/healthcheck/ready", to: GovukHealthcheck.rack_response(
    GovukHealthcheck::ActiveRecord,
    GovukHealthcheck::SidekiqRedis,
  )

  # Preview App standing in for Signon itself, so every previewed app gets
  # a real login instead of the old mock auth anyone could reach - see
  # OauthController/PreviewSignon. Paths fixed by gds-sso's own real OAuth2
  # strategy, not ours to choose.
  get "/oauth/authorize", to: "oauth#authorize"
  post "/oauth/access_token", to: "oauth_tokens#token"
  get "/user.json", to: "oauth_tokens#user_info"
  # Where HostRouter sends a browser back once it has a real session -
  # see OauthController#continue.
  get "/oauth/continue", to: "oauth#continue"

  resources :previews, only: %i[index new create destroy] do
    member do
      # Named so as not to shadow Kernel#sleep, or Ruby's `retry` keyword.
      post :sleep, action: :put_to_sleep
      post :wake
      post :retry, action: :retry_build
      post :resize
      get :confirm_destroy
      get :logs
    end
  end

  root to: redirect("/previews")
end

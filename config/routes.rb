Rails.application.routes.draw do
  get "/healthcheck/live", to: proc { [200, {}, %w[OK]] }
  get "/healthcheck/ready", to: GovukHealthcheck.rack_response(
    GovukHealthcheck::ActiveRecord,
    GovukHealthcheck::SidekiqRedis,
  )

  resources :previews, only: %i[index new create destroy] do
    member do
      # Named so as not to shadow Kernel#sleep, or Ruby's `retry` keyword.
      post :sleep, action: :put_to_sleep
      post :wake
      post :retry, action: :retry_build
      post :resize
      get :confirm_destroy
    end
  end

  root to: redirect("/previews")
end

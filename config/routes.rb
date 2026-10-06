Rails.application.routes.draw do
  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  resources :previews, only: %i[index new create destroy] do
    member do
      # Named so as not to shadow Kernel#sleep, or Ruby's `retry` keyword.
      post :sleep, action: :put_to_sleep
      post :wake
      post :retry, action: :retry_build
      post :resize
    end
  end

  root to: redirect("/previews")
end

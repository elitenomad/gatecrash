Rails.application.routes.draw do
  namespace :api do
    resources :events, only: %i[index], defaults: { format: :json }
    get "events/:slug", to: "events#show", as: :event

    resources :orders, only: %i[create show] do
      member do
        post :checkout
        get  :tickets
      end
    end

    # Provider webhooks. No CSRF, no session, no auth — the signature IS the
    # authentication, which is why verification cannot be optional.
    post "webhooks/stripe", to: "webhooks#stripe"

    namespace :admin do
      get  "orders/:order_id/ledger", to: "ledger#show"
      post "ledger/reconcile",        to: "ledger#reconcile"
    end
  end

  get "up", to: "rails/health#show", as: :rails_health_check
end

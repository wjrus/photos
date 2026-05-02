Rails.application.routes.draw do
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  get "/auth/failure", to: "sessions#failure"
  match "/auth/:provider/callback", to: "sessions#create", via: [ :get, :post ]
  delete "/sign_out", to: "sessions#destroy", as: :sign_out
  resources :photos, only: %i[show create] do
    post :retry_failed_archives, on: :collection
    get :display, on: :member
    get :media, on: :member
    patch :caption, on: :member
    patch :publish, on: :member
    patch :unpublish, on: :member
    post :retry_archive, on: :member
  end

  root "home#show"
end

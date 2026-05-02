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
  get "/map", to: "maps#show", as: :map
  resources :imports, only: %i[index create]
  get "/private", to: "restricted_photos#index", as: :restricted_photos
  post "/private/access", to: "restricted_photos#unlock", as: :unlock_restricted_photos
  delete "/private/access", to: "restricted_photos#lock", as: :lock_restricted_photos
  get "/uploads", to: "uploads#show", as: :uploads
  resource :album_bulk_actions, only: :create
  resource :photo_bulk_actions, only: :create
  resources :albums, only: %i[index show create update destroy] do
    patch :publish, on: :member
    patch :unpublish, on: :member
    resources :photo_album_memberships, only: :destroy, shallow: true
    patch "cover/:photo_id", to: "album_covers#update", as: :cover
  end
  resources :upload_chunks, only: :create do
    post :status, on: :collection
    post :complete, on: :collection
  end
  resources :photos, only: %i[show create destroy] do
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

Rails.application.routes.draw do
  namespace :api do
    namespace :v1 do
      get "capabilities", to: "capabilities#show"
      get "me", to: "capabilities#me"
      resource :session, only: %i[create destroy] do
        post :refresh
      end
      resources :devices, only: %i[index destroy]
      resource :restricted_access, only: %i[create destroy]
      resources :photos, only: %i[index show update destroy] do
        get :timeline, on: :collection
        post :bulk, on: :collection
        get :navigation, on: :member
        get :info, on: :member
        post :media_url, on: :member
        get "media/:variant", on: :member, action: :show, controller: "media", as: :media
        resources :people_tags, only: %i[create destroy]
      end
      resources :albums, only: %i[index show create update destroy] do
        post :bulk, on: :collection
        put :cover, on: :member
        post :photos, on: :member, action: :add_photos
        delete :photos, on: :member, action: :remove_photos
      end
      resources :photo_books, only: %i[index create]
      get "people", to: "people_tags#index"
      get "map", to: "maps#show"
      resources :locations, only: :index
      resources :uploads, only: %i[index create show destroy] do
        put "chunks/:position", on: :member, action: :chunk
        put :file, on: :member
        post :complete, on: :member
      end
    end
  end

  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check
  post "/webhooks/prodigi/:environment", to: "prodigi_webhooks#create", as: :prodigi_webhook
  get "/print_assets/:id/:kind", to: "prodigi_print_assets#show", as: :prodigi_print_asset
  get "/favicon.ico", to: redirect("/icon.png")

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  get "/auth/failure", to: "sessions#failure"
  match "/auth/:provider/callback", to: "sessions#create", via: [ :get, :post ]
  get "/sign_in", to: "sessions#new", as: :sign_in
  post "/sign_in", to: "sessions#password", as: :password_sign_in
  delete "/sign_out", to: "sessions#destroy", as: :sign_out
  resource :user_preferences, only: :update, path: "preferences"
  resource :password_reset, only: %i[new create], path: "password_reset"
  get "/password_reset/:token", to: "password_resets#edit", as: :edit_password_reset
  patch "/password_reset/:token", to: "password_resets#update", as: :update_password_reset
  get "/invitations/:token", to: "invitations#show", as: :invitation
  patch "/invitations/:token", to: "invitations#update", as: :accept_invitation
  resources :users, only: %i[index create destroy] do
    post :send_invitation, on: :member
    post :send_password_reset, on: :member
  end
  get "/archive", to: "archived_photos#index", as: :archived_photos
  get "/public", to: "public_photos#index", as: :public_photos
  resources :locations, only: %i[index show]
  patch "/locations/:location_id/cover/:photo_id", to: "location_covers#update", as: :location_cover
  get "/search", to: "search#show", as: :search
  get "/map", to: "maps#show", as: :map
  get "/map/markers", to: "maps#markers", as: :map_markers
  resources :imports, only: %i[index create]
  get "/repository_status", to: "repository_status#show", as: :repository_status
  get "/repository_status/panels/:panel", to: "repository_status#panel", as: :repository_status_panel, defaults: { format: :json }
  post "/repository_status", to: "repository_status#create"
  patch "/repository_status", to: "repository_status#update"
  get "/queues", to: "queue_status#show", as: :queue_status
  patch "/queues/failures/pruned", to: "queue_status#retry_pruned_failures", as: :retry_pruned_queue_failures
  delete "/queues/failures", to: "queue_status#destroy_failures", as: :queue_failures
  delete "/queues/pauses", to: "queue_status#resume_pauses", as: :queue_pauses
  get "/repository_health", to: "repository_health#show", as: :repository_health
  post "/repository_health", to: "repository_health#create"
  get "/private", to: "restricted_photos#index", as: :restricted_photos
  post "/private/access", to: "restricted_photos#unlock", as: :unlock_restricted_photos
  delete "/private/access", to: "restricted_photos#lock", as: :lock_restricted_photos
  get "/uploads", to: "uploads#show", as: :uploads
  resources :upload_batches, only: [] do
    patch :commit, on: :member
    delete :rollback, on: :member
  end
  resource :album_bulk_actions, only: :create
  resource :photo_bulk_actions, only: :create
  resources :photo_books do
    post :preview, on: :member
    get :tray, on: :member
    resources :pages, only: %i[create update destroy], controller: :photo_book_pages do
      patch :move, on: :member
    end
    resources :memberships, only: %i[create destroy], controller: :photo_book_memberships
    resources :exports, only: %i[create show], controller: :photo_book_exports do
      get :file, on: :member
    end
    resources :orders, only: %i[new create show edit update destroy], controller: :photo_book_orders do
      post :shipping, on: :member
      post :quote, on: :member
      post :submit, on: :member
      post :refresh, on: :member
      get :spine, on: :member
    end
  end
  resources :albums, only: %i[index show create update destroy] do
    patch :publish, on: :member
    patch :unpublish, on: :member
    resources :album_shares, only: %i[create destroy], shallow: true
    resources :access_links, only: :create, controller: :album_access_links
    resources :photo_album_memberships, only: :destroy, shallow: true
    patch "cover/:photo_id", to: "album_covers#update", as: :cover
  end
  patch "/album_access_links/:id/revoke", to: "album_access_links#revoke", as: :revoke_album_access_link
  resources :album_downloads, only: %i[create show] do
    get :file, on: :member
  end
  get "/photos/:photo_id/preview.jpg", to: "public_photo_images#show", as: :public_photo_image
  resources :upload_chunks, only: :create do
    post :status, on: :collection
    post :complete, on: :collection
  end
  resources :photos, only: %i[show create destroy] do
    post :retry_failed_archives, on: :collection
    get :stream, on: :member
    get :display, on: :member
    get :video, on: :member
    get :media, on: :member
    patch :caption, on: :member
    post :analyze, on: :member
    patch :manual_location, on: :member
    patch :publish, on: :member
    patch :unpublish, on: :member
    patch :archive, on: :member
    patch :restore, on: :member
    patch :restrict, on: :member
    patch :unrestrict, on: :member
    post :retry_archive, on: :member
    resource :file_health_check, only: :create, controller: :photo_file_health_checks
    resources :photo_album_memberships, only: :create, shallow: true
    resources :photo_book_memberships, only: :create
    resources :photo_people_tags, only: :create
  end
  resources :photo_people_tags, only: :destroy

  root "home#show"
end

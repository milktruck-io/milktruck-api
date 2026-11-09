Rails.application.routes.draw do
  # Devise sign-in/sign-up/password routes live under /auth so they do not
  # collide with the `resources :users` CRUD routes below (both would otherwise
  # claim POST /users).
  devise_for :users, path: "auth"

  # Trivia game show (temporary — one night only, see milktruck-web app/trivia).
  # No auth beyond the hardcoded host name in TriviaGame::ADMIN_NAME.
  scope "/trivia", module: "trivia", as: "trivia" do
    post "join", to: "games#join"
    get "state", to: "games#state"
    post "answer", to: "games#answer"
    post "advance", to: "games#advance"
    patch "players/:id/name", to: "games#rename", as: "player_name"
    patch "players/:id/subject", to: "games#set_subject", as: "player_subject"
    delete "players/:id", to: "games#kick", as: "player"
    match "*path", to: "games#preflight", via: :options
  end

  resources :events
  resources :clients
  resources :users
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # Defines the root path route ("/") — Devise redirects here after sign in.
  root "users#index"
end

# frozen_string_literal: true

Rails.application.routes.draw do
  root "comparison#index"

  post "select_db", to: "comparison#select_db", as: :select_db
  post "compare/:key", to: "comparison#compare", as: :compare
  post "refresh/:key", to: "comparison#refresh", as: :refresh
  post "mutate/:key", to: "comparison#mutate", as: :mutate
  post "reset/:key", to: "comparison#reset", as: :reset
end

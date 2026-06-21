# frozen_string_literal: true

Rails.application.routes.draw do
  root "comparison#index"

  post "raw/:key", to: "comparison#raw", as: :raw
  post "materialized/:key", to: "comparison#materialized", as: :materialized
  post "refresh/:key", to: "comparison#refresh", as: :refresh
  post "mutate/:key", to: "comparison#mutate", as: :mutate
end

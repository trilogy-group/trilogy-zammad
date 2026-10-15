# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

Zammad::Application.routes.draw do
  scope Rails.configuration.api_path do
    get '/legal_intake/ticket_timelines', to: 'legal_intake_ticket_timelines#index'
  end
end

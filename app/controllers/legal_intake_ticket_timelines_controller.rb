# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

# Trilogy fork: read-only, batched "where does each ticket stand" timings for
# the Legal Intake attention dashboard.
#
#   GET /api/v1/legal_intake/ticket_timelines?ids=1,2,3
#
# Returns ONLY timestamps and user ids derived from the state-history log and
# article metadata (never article bodies, never internal-note content), for
# the tickets the CURRENT user may read (TicketPolicy::ReadScope: agent group
# access, own tickets, shared tickets). Unknown or invisible ids are omitted.
# The computation lives in Service::Ticket::LegalIntakeTimelines.
class LegalIntakeTicketTimelinesController < ApplicationController
  prepend_before_action :authenticate_and_authorize!

  MAX_IDS = 500

  def index
    tickets = TicketPolicy::ReadScope.new(current_user).resolve.where(id: requested_ids).to_a

    timelines = Service::Ticket::LegalIntakeTimelines
      .new(tickets, agent_view: current_user.permissions?('ticket.agent'))
      .execute

    render json: { timelines: timelines }
  end

  private

  def requested_ids
    raw = params[:ids].to_s.split(',').map(&:strip).compact_blank
    raise Exceptions::UnprocessableEntity, __('Provide ids as a comma-separated list of ticket ids.') if raw.empty?
    raise Exceptions::UnprocessableEntity, "At most #{MAX_IDS} ticket ids per request." if raw.size > MAX_IDS

    raw.map { |v| Integer(v, 10) }.uniq
  rescue ArgumentError
    raise Exceptions::UnprocessableEntity, __('Ticket ids must be integers.')
  end
end

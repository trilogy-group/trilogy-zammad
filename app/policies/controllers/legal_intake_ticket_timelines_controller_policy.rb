# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

# Any signed-in agent or customer may ask; the controller scopes the ticket
# set to what that user can read.
class Controllers::LegalIntakeTicketTimelinesControllerPolicy < Controllers::ApplicationControllerPolicy
  default_permit!(['ticket.agent', 'ticket.customer'])
end

# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

class Controllers::TicketSharedAccessesControllerPolicy < Controllers::ApplicationControllerPolicy
  def index?
    # Anyone who can see the ticket may see who it is shared with.
    ticket_visible?
  end

  def create?
    can_share?
  end

  def destroy?
    can_unshare?
  end

  def search?
    # Anyone who can share the ticket may search for customers to share it with.
    can_share?
  end

  private

  def ticket
    @ticket ||= Ticket.find(record.params[:ticket_id])
  end

  # True when the current user can access the ticket by ANY path
  # (agent with group access, ticket owner/customer, shared customer, or shared organization).
  # This is the single source of truth for "is a party to the ticket".
  def ticket_visible?
    return true if user.permissions?('admin')

    TicketPolicy.new(user, ticket).show?
  end

  # Anyone who can access the ticket may grant another customer access to it.
  # Covers: admins, agents with group access, the submitting customer, and
  # customers the ticket was already shared with.
  def can_share?
    ticket_visible?
  end

  def can_unshare?
    shared_access = Ticket::SharedAccess.find_by(id: record.params[:id])
    return false if !shared_access

    # Admins can remove any shared access (for API/automation purposes).
    return true if user.permissions?('admin')

    access_ticket = shared_access.ticket

    # Agents with access to the ticket's group can remove anyone.
    return true if TicketPolicy.new(user, access_ticket).agent_read_access?

    # The ticket owner (submitting customer) can remove anyone.
    return true if access_ticket.customer_id == user.id

    # Shared customers can only remove themselves.
    return true if shared_access.user_id == user.id

    false
  end
end

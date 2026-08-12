# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

module Gql::Types::Input
  class TemplateRenderContextInputType < Gql::Types::BaseInputObject
    description 'Context data for template rendering, e.g. customer data.'

    argument :customer_id, GraphQL::Types::ID, loads: Gql::Types::UserType, required: false, description: 'Ticket customer (if no ticket exists yet)'
    argument :ticket_id, GraphQL::Types::ID, loads: Gql::Types::TicketType, required: false, description: 'Ticket'
    argument :user_id, GraphQL::Types::ID, loads: Gql::Types::UserType, required: false, description: 'User (if not present the currently logged in user will be passed)'
    argument :group_id, GraphQL::Types::ID, loads: Gql::Types::GroupType, required: false, description: 'Group'
    argument :organization_id, GraphQL::Types::ID, loads: Gql::Types::OrganizationType, required: false, description: 'Organization'
    # Legal-intake cascade: the agent's currently-selected (possibly unsaved)
    # Business Unit name, forwarded by the form so a cascading search_url
    # (#{ticket.li_business_unit}) reflects the live pick, not the saved value.
    argument :li_business_unit_live, String, required: false, description: 'Live (unsaved) ticket Business Unit name for cascading lookups'

    # Prepare a hash suitable for usage in NotificationFactory.
    def to_context_hash
      to_h.tap do |result|

        # Inject current user as `user` if needed.
        result[:user] ||= context.current_user

        # If ticket does not exist yet, fake it with a customer if present.
        if !ticket && customer
          result[:ticket] = ::Ticket.new(customer: customer)
        end

        # Cascade: prefer the LIVE Business Unit over the persisted ticket's.
        # `to_h` carries the raw string key; li_business_unit is a jsonb
        # {value,label} column, so assign the shape the renderer stringifies.
        # Guard with respond_to? so this no-ops where the column isn't migrated.
        live_bu = result.delete(:li_business_unit_live).to_s.strip
        if live_bu.present?
          result[:ticket] ||= ::Ticket.new
          ticket = result[:ticket]
          if ticket.respond_to?(:li_business_unit=)
            ticket.li_business_unit = { 'value' => live_bu, 'label' => live_bu }
          end
        end

      end
    end
  end
end

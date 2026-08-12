# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

class ExternalDataSourceController < ApplicationController
  prepend_before_action :authenticate_and_authorize!

  def fetch
    result = Service::ExternalDataSource::Search.new.execute(
      attribute:      attribute,
      render_context: render_context,
      term:           params[:query],
      limit:          (params[:limit].presence || 10).to_i,
    )

    render json: {
      result: result,
    }
  end

  def preview
    result = Service::ExternalDataSource::Preview.new.execute(
      data_option:    params[:data_option],
      render_context: render_context,
      term:           params[:query],
      limit:          (params[:limit].presence || 10).to_i,
    )

    render json: result
  end

  private

  def attribute
    ::ObjectManager::Attribute.get(object: params[:object], name: params[:attribute]).tap do |attribute|
      raise "Could not find object attribute for #{params}." if !attribute
    end
  end

  def render_context
    search_context = params.fetch(:search_context, {})

    result = [::Ticket, ::Group, ::User, ::Organization].each_with_object({}) do |model, memo|
      param_value = search_context["#{model.name.downcase}_id"]

      next if !param_value

      memo[model.name.downcase.to_sym] = model.find_by(id: param_value)
    end

    result[:user] ||= current_user

    # If ticket does not exist yet, fake it with a customer if present.
    inject_ticket(search_context, result)

    # Cascade support: when the agent has picked (but not yet saved) a new
    # Business Unit, the frontend forwards it as search_context['li_business_unit_live'].
    # Prefer that LIVE value over the persisted ticket's li_business_unit so the
    # product search_url's #{ticket.li_business_unit} reflects the unsaved pick.
    inject_live_business_unit(search_context, result)

    result
  end

  def inject_ticket(search_context, result)
    return if result[:ticket]
    return if !search_context['customer_id']

    customer = ::User.find_by(id: search_context['customer_id'])

    return if !customer

    result[:ticket] = ::Ticket.new(customer: customer)
  end

  def inject_live_business_unit(search_context, result)
    live_bu = search_context['li_business_unit_live'].to_s.strip
    return if live_bu.blank?

    # Ensure there is a ticket object in the context to hang the live value on.
    result[:ticket] ||= ::Ticket.new

    # li_business_unit is an autocompletion_ajax_external_data_source (jsonb
    # {value,label}) column; assign the shape the template renderer stringifies
    # to the human-readable name. Guard with respond_to? for unmigrated schemas.
    ticket = result[:ticket]
    ticket.li_business_unit = { 'value' => live_bu, 'label' => live_bu } if ticket.respond_to?(:li_business_unit=)
  end
end

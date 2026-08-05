# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

require 'rails_helper'

describe Controllers::TicketSharedAccessesControllerPolicy do
  subject { described_class.new(user, record) }

  let(:record_class) { TicketSharedAccessesController }
  let(:group)        { create(:group) }
  let(:ticket)       { create(:ticket, group: group) }
  let(:params)       { { ticket_id: ticket.id } }
  let(:record)       { record_class.new.tap { it.params = params } }

  describe 'sharing (index?/create?/search?)' do
    context 'when user is an admin' do
      let(:user) { create(:admin) }

      it { is_expected.to permit_actions(:index, :create, :search) }
    end

    context 'when user is an agent WITH access to the ticket group' do
      let(:user) { create(:agent, groups: [group]) }

      it { is_expected.to permit_actions(:index, :create, :search) }
    end

    context 'when user is an agent WITHOUT access to the ticket group' do
      let(:user) { create(:agent) }

      it { is_expected.to forbid_actions(:index, :create, :search) }
    end

    context 'when user is the ticket customer (submitter)' do
      let(:user) { ticket.customer }

      it { is_expected.to permit_actions(:index, :create, :search) }
    end

    context 'when user is a customer the ticket was shared with' do
      let(:user) { create(:customer) }

      before { Ticket::SharedAccess.share!(ticket, user, created_by: ticket.customer) }

      it { is_expected.to permit_actions(:index, :create, :search) }
    end

    context 'when user is an unrelated customer' do
      let(:user) { create(:customer) }

      it { is_expected.to forbid_actions(:index, :create, :search) }
    end
  end

  describe 'unsharing (destroy?)' do
    let(:shared_customer) { create(:customer) }
    let(:other_customer)  { create(:customer) }
    let!(:shared_access)  { Ticket::SharedAccess.share!(ticket, shared_customer, created_by: ticket.customer) }
    let(:params)          { { ticket_id: ticket.id, id: shared_access.id } }

    context 'when user is an admin' do
      let(:user) { create(:admin) }

      it { is_expected.to permit_actions(:destroy) }
    end

    context 'when user is an agent WITH access to the ticket group' do
      let(:user) { create(:agent, groups: [group]) }

      it { is_expected.to permit_actions(:destroy) }
    end

    context 'when user is an agent WITHOUT access to the ticket group' do
      let(:user) { create(:agent) }

      it { is_expected.to forbid_actions(:destroy) }
    end

    context 'when user is the ticket owner (submitting customer)' do
      let(:user) { ticket.customer }

      it { is_expected.to permit_actions(:destroy) }
    end

    context 'when user is the shared customer removing themselves' do
      let(:user) { shared_customer }

      it { is_expected.to permit_actions(:destroy) }
    end

    context 'when user is a DIFFERENT shared customer' do
      let(:user) { other_customer }

      before { Ticket::SharedAccess.share!(ticket, other_customer, created_by: ticket.customer) }

      it { is_expected.to forbid_actions(:destroy) }
    end

    context 'when the shared access does not exist' do
      let(:user)   { create(:admin) }
      let(:params) { { ticket_id: ticket.id, id: 0 } }

      it { is_expected.to forbid_actions(:destroy) }
    end
  end
end

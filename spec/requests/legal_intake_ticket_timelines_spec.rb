# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

require 'rails_helper'

RSpec.describe 'Legal Intake ticket timelines', :aggregate_failures, type: :request do
  let(:open_type)  { Ticket::StateType.find_by(name: 'open') }
  let!(:submitted) { create(:ticket_state, name: 'submitted_to_legal', state_type: open_type) }
  let!(:review)    { create(:ticket_state, name: 'under_legal_review', state_type: open_type) }

  let(:group)        { create(:group) }
  let(:legal_admin_role) { create(:role, name: 'Legal Admin', permission_names: %w[ticket.agent]) }
  let(:coordinator)      { create(:agent, groups: [group], roles: [Role.find_by(name: 'Agent'), legal_admin_role]) }
  let(:attorney)         { create(:agent, groups: [group]) }
  let(:customer)         { create(:customer) }
  let(:other)            { create(:customer) }
  let(:shared_with)      { create(:customer) }
  let(:intake_app)       { create(:admin, email: 'legal-intake-admin@legal-intake.com', login: 'legal-intake-admin@legal-intake.com') }

  let(:ticket) { create(:ticket, group: group, customer: customer, state: submitted, created_at: 10.days.ago) }
  let(:foreign_ticket) { create(:ticket, group: group, customer: other, state: submitted) }

  def as_user(user)
    UserInfo.current_user_id = user.id
    yield
  ensure
    UserInfo.current_user_id = nil
  end

  def article(author:, sender:, internal: false, time: Time.zone.now)
    create(:ticket_article, ticket: ticket, created_by_id: author.id, updated_by_id: author.id,
           sender_name: sender, internal: internal, created_at: time)
  end

  def timelines(ids)
    get "/api/v1/legal_intake/ticket_timelines?ids=#{ids.join(',')}", as: :json
    expect(response).to have_http_status(:ok)
    json_response['timelines']
  end

  before do
    # The intake app posts the submission articles on the requester's behalf.
    article(author: intake_app, sender: 'Customer', time: 10.days.ago)
    as_user(coordinator) { ticket.update!(owner: attorney) }
    as_user(attorney) { ticket.update!(state: review) }
  end

  describe 'visibility' do
    it 'returns only tickets the customer may read' do
      authenticated_as(customer)
      result = timelines([ticket.id, foreign_ticket.id])
      expect(result.pluck('ticket_id')).to eq([ticket.id])
    end

    it 'includes tickets shared with the customer' do
      Ticket::SharedAccess.share!(ticket, shared_with, created_by: customer)
      authenticated_as(shared_with)
      expect(timelines([ticket.id]).pluck('ticket_id')).to eq([ticket.id])
    end

    it 'returns group tickets to an agent' do
      authenticated_as(attorney)
      expect(timelines([ticket.id, foreign_ticket.id]).pluck('ticket_id')).to contain_exactly(ticket.id, foreign_ticket.id)
    end

    it 'never returns article bodies' do
      authenticated_as(customer)
      expect(response_body_after { timelines([ticket.id]) }).not_to include(ticket.articles.first.body)
    end

    it 'rejects a missing id list' do
      authenticated_as(customer)
      get '/api/v1/legal_intake/ticket_timelines', as: :json
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it 'rejects more than 500 ids' do
      authenticated_as(customer)
      get "/api/v1/legal_intake/ticket_timelines?ids=#{(1..501).to_a.join(',')}", as: :json
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe 'timings' do
    it 'records state segments and the submission time' do
      authenticated_as(attorney)
      t = timelines([ticket.id]).first
      expect(t['segments'].pluck('state')).to eq(%w[submitted_to_legal under_legal_review])
      expect(Time.zone.parse(t['submitted_at'])).to be_within(1.second).of(ticket.created_at)
      expect(t['state']).to eq('under_legal_review')
    end

    it 'is waiting on legal since the submission while legal has not visibly acted' do
      authenticated_as(attorney)
      t = timelines([ticket.id]).first
      expect(Time.zone.parse(t['waiting_on_legal_since'])).to be_within(1.second).of(ticket.created_at)
      expect(t['last_legal_action_at']).to be_nil
    end

    it 'does not count internal notes or service-account articles as legal actions' do
      article(author: attorney, sender: 'Agent', internal: true)
      article(author: intake_app, sender: 'Agent')
      authenticated_as(attorney)
      expect(timelines([ticket.id]).first['last_legal_action_at']).to be_nil
    end

    it 'clears the wait on a public legal note and restarts it on the next requester message' do
      article(author: attorney, sender: 'Agent', time: 2.days.ago)
      authenticated_as(attorney)
      expect(timelines([ticket.id]).first['waiting_on_legal_since']).to be_nil

      reply = article(author: customer, sender: 'Customer', time: 1.day.ago)
      t = timelines([ticket.id]).first
      expect(Time.zone.parse(t['waiting_on_legal_since'])).to be_within(1.second).of(reply.created_at)
    end

    it 'names the legal admin who routed the ticket' do
      authenticated_as(attorney)
      t = timelines([ticket.id]).first
      expect(t['owner_id']).to eq(attorney.id)
      expect(t['assigned_by_id']).to eq(coordinator.id)
      expect(t['legal_admin_assigner_id']).to eq(coordinator.id)
    end

    it 'keeps the legal admin assigner after an attorney hand-off' do
      second = create(:agent, groups: [group])
      as_user(attorney) { ticket.update!(owner: second) }
      authenticated_as(attorney)
      t = timelines([ticket.id]).first
      expect(t['assigned_by_id']).to eq(attorney.id)
      expect(t['legal_admin_assigner_id']).to eq(coordinator.id)
    end

    it 'credits the creator when the ticket was created with an owner' do
      created = create(:ticket, group: group, customer: customer, owner: attorney, created_by: coordinator)
      authenticated_as(attorney)
      t = timelines([created.id]).first
      expect(t['assigned_by_id']).to eq(coordinator.id)
      expect(t['legal_admin_assigner_id']).to eq(coordinator.id)
    end

    it 'keeps counting a reply by an attorney who was later deactivated' do
      create(:ticket_article, ticket: ticket, sender_name: 'Agent', internal: false, created_by: attorney, created_at: 1.hour.ago)
      attorney.update!(active: false)
      authenticated_as(coordinator)
      expect(timelines([ticket.id]).first['last_legal_action_at']).to be_present
    end

    it 'keeps the creating Legal Admin as coordinator after an attorney hand-off' do
      other = create(:agent, groups: [group])
      created = create(:ticket, group: group, customer: customer, owner: attorney, created_by: coordinator)
      created.update!(owner: other, updated_by_id: attorney.id)
      authenticated_as(coordinator)
      expect(timelines([created.id]).first['legal_admin_assigner_id']).to eq(coordinator.id)
    end

    it 'does not credit a Legal Admin who created the ticket unassigned' do
      created = create(:ticket, group: group, customer: customer, created_by: coordinator)
      as_user(attorney) { created.update!(owner: attorney) }
      authenticated_as(attorney)
      t = timelines([created.id]).first
      expect(t['assigned_by_id']).to eq(attorney.id)
      expect(t['legal_admin_assigner_id']).to be_nil
    end

    it 'gives customers no staff emails and no coordinator' do
      authenticated_as(customer)
      t = timelines([ticket.id]).first
      expect(t['owner']).to include('id' => attorney.id, 'email' => nil)
      expect(t['legal_admin_assigner']).to be_nil
      expect(t['legal_admin_assigner_id']).to be_nil
      expect(response.body).not_to include(coordinator.email)
    end

    it 'gives agents staff emails' do
      authenticated_as(attorney)
      expect(timelines([ticket.id]).first['owner']).to include('email' => attorney.email)
    end

    it 'reports the escalated tag' do
      as_user(coordinator) { ticket.tag_add('escalated', coordinator.id) }
      authenticated_as(customer)
      expect(timelines([ticket.id]).first['escalation']).to include('active' => true)
    end
  end

  def response_body_after
    yield
    response.body
  end
end

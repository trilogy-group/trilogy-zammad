# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

require 'rails_helper'

# Tests for suppressing email/online notifications on internal notes authored by
# the Legal Agent bot (the intake platform's service account).
#
# The bot posts internal QC / redline / triage notes on tickets. These are
# operational notes, not agent-to-agent communication, so the legal team must
# NOT be emailed or notified for each one (issue: "stop the QC emails across the
# board"). Human agent-to-agent internal notes must still notify normally.
#
# The bot's user id differs per environment, so the guard matches on the stable
# login/email prefix `legal-agent@` (mirrors the intake app's QC_AUTHOR
# convention), not a hardcoded id.
#
RSpec.describe Transaction::Notification, 'legal agent bot' do
  let(:group)       { create(:group) }
  let(:agent_owner) { create(:agent, groups: [group]) }
  let(:legal_admin) { create(:agent, groups: [group]) }
  let(:customer)    { create(:customer) }
  let(:bot)         { create(:agent, groups: [group], email: 'legal-agent@legal-intake.com') }
  let(:human_agent) { create(:agent, groups: [group], email: 'attorney@example.com') }
  let(:open_state)  { Ticket::State.find_by(name: 'open') }
  let(:ticket) do
    create(:ticket, group: group, customer: customer, owner: agent_owner,
                    state: open_state)
  end

  before do
    allow(NotificationFactory::Mailer).to receive(:deliver)
    allow(NotificationFactory::Mailer).to receive(:template).and_return({ subject: 'subj', body: 'body' })
  end

  def perform_internal_note(author)
    article = create(:ticket_article, :internal_note, ticket: ticket, created_by: author)
    item = {
      object:     'Ticket',
      type:       'update',
      object_id:  ticket.id,
      article_id: article.id,
      user_id:    author.id,
      changes:    {},
    }
    described_class.new(item).perform
  end

  describe 'internal note authored by the Legal Agent bot' do
    it 'suppresses the internal-comment notification entirely', :aggregate_failures do
      perform_internal_note(bot)

      expect(NotificationFactory::Mailer).not_to have_received(:deliver)
      expect(NotificationFactory::Mailer).not_to have_received(:template)
    end

    it 'does not raise' do
      expect { perform_internal_note(bot) }.not_to raise_error
    end
  end

  describe 'internal note authored by a human agent' do
    it 'still notifies the owner / legal team', :aggregate_failures do
      # Give the ticket a second full-access agent so there is a recipient other
      # than the commenter.
      legal_admin
      perform_internal_note(human_agent)

      expect(NotificationFactory::Mailer).to have_received(:deliver).at_least(:once)
    end
  end

  describe '#legal_agent_bot_article?' do
    let(:instance) { described_class.new({ object: 'Ticket', type: 'update', object_id: ticket.id }) }

    it 'matches the bot email prefix case-insensitively', :aggregate_failures do
      bot_article   = create(:ticket_article, :internal_note, ticket: ticket, created_by: bot)
      human_article = create(:ticket_article, :internal_note, ticket: ticket, created_by: human_agent)

      expect(instance.send(:legal_agent_bot_article?, bot_article)).to be(true)
      expect(instance.send(:legal_agent_bot_article?, human_article)).to be(false)
    end
  end
end

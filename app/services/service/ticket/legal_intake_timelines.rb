# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

# Trilogy fork: computes the Legal Intake attention-dashboard timeline for a
# set of tickets the caller has ALREADY been authorized to read (see
# LegalIntakeTicketTimelinesController). Reads only metadata: state/owner/tag
# history rows and article (id, time, author, sender, internal) tuples.
#
# Definitions match the Q4 2026 response-time research
# (legal-intake-brain/research/2026-10-05-response-time-baseline):
#   - requester action: the submission to legal (first entry into
#     submitted_to_legal, or creation in it), or a public article by a human
#     customer-side user;
#   - visible legal action: a public article by a human legal-side user, or a
#     human legal-side change of the state to resolved/closed.
#   - legal side = users with the ticket.agent permission.
# Service accounts (system user 1, the intake app, the Legal Agent bot) are
# never "human". They are matched by email local part, NOT by numeric id: the
# ids differ per environment (prod user 4 is the intake app, staging user 4 is
# a person).
class Service::Ticket::LegalIntakeTimelines < Service::Base
  SERVICE_LOCAL_PARTS = %w[legal-intake legal-intake-admin legal-agent legal-agent-bot migrator].freeze
  LEGAL_ADMIN_ROLE    = 'Legal Admin'.freeze # rubocop:disable Zammad/DetectTranslatableString
  ESCALATION_TAG      = 'escalated'.freeze
  RESPONSE_STATES     = %w[resolved closed].freeze
  SUBMITTED_STATE     = 'submitted_to_legal'.freeze
  SYSTEM_USER_ID      = 1

  Event = Struct.new(:kind, :at, :by, :from, :to, :id_from, :id_to, keyword_init: true)

  def initialize(tickets)
    super()
    @tickets = tickets
  end

  def execute
    return [] if @tickets.empty?

    ids = @tickets.map(&:id)
    events   = load_events(ids)
    articles = load_articles(ids)
    tags     = load_tags(ids)
    load_users(events.values.flatten.map(&:by) + articles.values.flatten.pluck(:by) + @tickets.map(&:owner_id))

    @tickets.map do |ticket|
      timeline_for(ticket, events[ticket.id] || [], articles[ticket.id] || [], tags[ticket.id] || [])
    end
  end

  private

  # --- loading -------------------------------------------------------------

  def load_events(ids) # rubocop:disable Metrics/AbcSize
    object_id = History::Object.lookup(name: 'Ticket')&.id
    attrs     = %w[state owner tag].index_with { |n| History::Attribute.lookup(name: n)&.id }.compact
    return {} if object_id.nil? || attrs.empty?

    attr_names = attrs.invert
    type_names = History::Type.all.to_h { |t| [t.id, t.name] }

    History
      .where(history_object_id: object_id, o_id: ids, history_attribute_id: attrs.values)
      .reorder(:created_at, :id)
      .pluck(:o_id, :history_attribute_id, :history_type_id, :value_from, :value_to, :id_from, :id_to, :created_by_id, :created_at)
      .each_with_object(Hash.new { |h, k| h[k] = [] }) do |(o_id, attr_id, type_id, v_from, v_to, id_from, id_to, by, at), acc|
        kind = case attr_names[attr_id]
               when 'state' then :state
               when 'owner' then :owner
               when 'tag' then type_names[type_id] == 'removed' ? :tag_removed : :tag_added
               end
        next if kind.nil?

        acc[o_id] << Event.new(kind: kind, at: at, by: by, from: v_from, to: v_to, id_from: id_from, id_to: id_to)
      end
  end

  def load_articles(ids)
    senders = Ticket::Article::Sender.all.to_h { |s| [s.id, s.name] }
    Ticket::Article
      .where(ticket_id: ids)
      .reorder(:created_at, :id)
      .pluck(:ticket_id, :created_at, :created_by_id, :sender_id, :internal)
      .each_with_object(Hash.new { |h, k| h[k] = [] }) do |(ticket_id, at, by, sender_id, internal), acc|
        acc[ticket_id] << { at: at, by: by, sender: senders[sender_id], internal: internal }
      end
  end

  def load_tags(ids)
    object = Tag::Object.lookup(name: 'Ticket')
    return {} if object.nil?

    Tag
      .joins(:tag_item)
      .where(tag_object_id: object.id, o_id: ids)
      .pluck(:o_id, 'tag_items.name')
      .each_with_object(Hash.new { |h, k| h[k] = [] }) { |(o_id, name), acc| acc[o_id] << name }
  end

  def load_users(user_ids)
    @users = User.where(id: user_ids.compact.uniq).includes(:roles).index_by(&:id)
    @human = {}
    @legal = {}
    @legal_admin = {}
    @users.each do |id, user|
      local = user.email.to_s.downcase.split('@').first.to_s
      service = id == SYSTEM_USER_ID || SERVICE_LOCAL_PARTS.include?(local)
      @human[id] = !service
      @legal[id] = !service && user.permissions?('ticket.agent')
      @legal_admin[id] = !service && user.roles.any? { |r| r.name == LEGAL_ADMIN_ROLE }
    end
  end

  # Display info for an attorney / coordinator (both already visible to the
  # ticket's customers in the help desk UI as the ticket owner / authors).
  def person(user_id)
    user = user_id && @users[user_id]
    return nil if user.nil?

    { id: user.id, name: user.fullname.presence, email: user.email.presence }
  end

  def human?(user_id)        = @human[user_id] == true
  def legal?(user_id)        = @legal[user_id] == true
  def legal_admin?(user_id)  = @legal_admin[user_id] == true
  def requester?(user_id)    = human?(user_id) && !legal?(user_id)

  # --- per ticket ----------------------------------------------------------

  def timeline_for(ticket, events, articles, tags) # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
    state_events = events.select { |e| e.kind == :state }
    segments     = build_segments(ticket, state_events)
    submitted_at = submission_time(ticket, segments)

    requester_actions = articles.select { |a| !a[:internal] && a[:sender] == 'Customer' && requester?(a[:by]) }.pluck(:at)
    requester_actions.unshift(submitted_at) if submitted_at
    legal_actions = articles.select { |a| !a[:internal] && legal?(a[:by]) }.pluck(:at) +
                    state_events.select { |e| RESPONSE_STATES.include?(e.to) && legal?(e.by) }.map(&:at)
    public_activity = articles.select { |a| !a[:internal] && human?(a[:by]) }.pluck(:at) +
                      state_events.select { |e| human?(e.by) }.map(&:at)

    last_legal = legal_actions.max
    waiting_since = requester_actions.sort.find { |t| last_legal.nil? || t > last_legal }
    assigned = assignment(ticket, events)

    {
      ticket_id:                ticket.id,
      state:                    ticket.state&.name,
      created_at:               ticket.created_at,
      state_since:              segments.last&.dig(:from),
      segments:                 segments,
      submitted_at:             submitted_at,
      owner_id:                 ticket.owner_id == SYSTEM_USER_ID ? nil : ticket.owner_id,
      owner:                    person(ticket.owner_id == SYSTEM_USER_ID ? nil : ticket.owner_id),
      assigned_at:              assigned[:at],
      assigned_by_id:           assigned[:by],
      legal_admin_assigner_id:  assigned[:legal_admin_by],
      legal_admin_assigner:     person(assigned[:legal_admin_by]),
      waiting_on_legal_since:   waiting_since,
      last_legal_action_at:     last_legal,
      last_requester_action_at: requester_actions.max,
      last_public_activity_at:  public_activity.max,
      escalation:               escalation(events, tags, legal_actions),
    }
  end

  # Contiguous stays per state. The first stay starts at creation in the state
  # the first recorded change moved FROM (or the current state, if none).
  def build_segments(ticket, state_events)
    initial = state_events.first&.from || ticket.state&.name
    segments = [{ state: initial, from: ticket.created_at, to: nil }]
    state_events.each do |e|
      next if e.to == segments.last[:state]

      segments.last[:to] = e.at
      segments << { state: e.to, from: e.at, to: nil }
    end
    segments
  end

  def submission_time(_ticket, segments)
    segments.find { |s| s[:state] == SUBMITTED_STATE }&.dig(:from)
  end

  # Who assigned the CURRENT owner: the latest owner change to them; plus the
  # latest change on the ticket made by a Legal Admin (the coordinator who
  # routed it), walking back past attorney hand-offs.
  def assignment(ticket, events)
    owner_events = events.select { |e| e.kind == :owner }
    return {} if ticket.owner_id.nil? || ticket.owner_id == SYSTEM_USER_ID

    to_owner = owner_events.reverse.find { |e| e.id_to == ticket.owner_id }
    by_admin = owner_events.reverse.find { |e| e.id_to.present? && e.id_to != SYSTEM_USER_ID && legal_admin?(e.by) }
    { at: to_owner&.at, by: to_owner&.by, legal_admin_by: by_admin&.by }
  end

  # The `escalated` tag is the single source of truth. Removal history keeps
  # the tag's CREATOR as created_by (Tag#destroy), so who cleared it is not
  # recoverable here; the app records that when it clears via its button.
  def escalation(events, tags, legal_actions)
    added   = events.reverse.find { |e| e.kind == :tag_added && e.to == ESCALATION_TAG }
    removed = events.reverse.find { |e| e.kind == :tag_removed && e.to == ESCALATION_TAG }
    active  = tags.include?(ESCALATION_TAG)
    since   = active ? added&.at : nil
    {
      active:                active,
      since:                 since,
      legal_responded_since: since.present? && legal_actions.any? { |t| t > since },
      last_cleared_at:       removed&.at,
    }
  end
end

# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

class Transaction::Notification
  include ChecksHumanChanges

=begin
  {
    object: 'Ticket',
    type: 'update',
    object_id: 123,
    interface_handle: 'application_server', # application_server|websocket|scheduler
    changes: {
      'attribute1' => [before, now],
      'attribute2' => [before, now],
    },
    created_at: Time.zone.now,
    user_id: 123,
  },
=end

  attr_accessor :recipients_and_channels, :recipients_reason

  def initialize(item, params = {})
    @item                    = item
    @params                  = params
    @recipients_and_channels = []
    @recipients_reason       = {}
  end

  def ticket
    @ticket ||= Ticket.find_by(id: @item[:object_id])
  end

  def article_by_item
    return if !@item[:article_id]

    article = Ticket::Article.find(@item[:article_id])

    # ignore notifications
    sender = Ticket::Article::Sender.lookup(id: article.sender_id)
    if sender&.name == 'System'
      return if @item[:changes].blank? && article.preferences[:notification] != true

      if article.preferences[:notification] != true
        article = nil
      end
    end

    article
  end

  def article
    return nil if @suppress_article_for_state_change

    @article ||= article_by_item
  end

  def current_user
    @current_user ||= User.lookup(id: @item[:user_id]) || User.lookup(id: 1)
  end

  # The Legal Agent bot (the intake platform's service account) posts internal
  # QC / redline / triage notes on tickets. These are operational notes, not
  # agent-to-agent communication, so the legal team should not be emailed or
  # notified about them. The bot's user id differs per environment
  # (prod/staging/local), but its login/email prefix is stable, so match on that
  # rather than a hardcoded id. Matches the intake app's QC_AUTHOR convention
  # (legal-agent@<env-domain>).
  def legal_agent_bot_article?(article)
    email = article.created_by&.email
    return false if email.blank?

    email.downcase.start_with?('legal-agent@')
  end

  def perform
    # return if we run import mode
    if Setting.get('import_mode')
      return
    end

    if %w[Ticket Ticket::Article].exclude?(@item[:object])
      return
    end

    if @params[:disable_notification]
      return
    end

    if !ticket
      return
    end

    # Block only state change notifications for submitted_to_legal
    # Allow comment notifications to go through
    # If this is a state change notification (not a comment), block it
    if (ticket.state.name == 'submitted_to_legal') && @item[:type] == 'update' && @item[:changes]&.key?('state_id')
      return
    end

    # Allow comments and other updates to proceed

    prepare_recipients_and_reasons

    # Check if this is an internal comment (agent inter-communication)
    if article&.internal
      # Legal Agent bot notes (QC / redline / triage) are internal notes posted
      # by the service account, not agent-to-agent communication. The legal team
      # does not want an email/notification for every one of these operational
      # notes, so suppress notifications for bot-authored internal articles.
      # Human agent-to-agent internal notes still notify normally.
      send_internal_comment_notification(article) if !legal_agent_bot_article?(article)
      return
    end

    # Check if this is a regular comment (non-internal)
    # BUT: If this is the first article of a newly created ticket, treat it as creation, not comment
    #
    # Priority rule: Comment > Status > Owner
    # When a comment is present, only the comment notification fires — no separate state or owner emails.
    if article && @item[:type] == 'update'
      send_comment_notification_with_cc(article)
      return
    end

    # For creation notifications, send ONE email with CC (customer To, agents CC)
    # This handles both: ticket creation without article AND ticket creation with first article
    if @item[:type] == 'create'
      send_creation_notification_with_cc
    elsif @item[:type] == 'update' && (@item[:changes]&.key?('owner_id') || @item[:changes]&.key?('state_id'))
      # Priority rule (no article present): Status > Owner
      # If state changed, send state notification only (owner change is lower priority).
      # If only owner changed (no state change), send assignment notification.
      if @item[:changes]&.key?('state_id')
        if ticket.state.name == 'under_legal_review'
          send_under_legal_review_notification_with_cc
        elsif %w[awaiting_response ready_for_signature sent_for_signature signed resolved closed].include?(ticket.state.name) || reopened_state?(ticket, @item[:changes])
          send_state_change_notification_with_cc
        end
      elsif @item[:changes]&.key?('owner_id')
        send_assignment_notification_with_cc
      end
    end
    # No email notifications for other field updates (priority, custom fields, group, etc.)
    # Only send emails for: ticket creation, comments/articles, state changes, and owner-only assignments.
  end

  def prepare_recipients_and_reasons

    # loop through all group users
    possible_recipients = possible_recipients_of_group(ticket.group_id)

    # loop through all mention users
    mention_users = Mention.where(mentionable_type: @item[:object], mentionable_id: @item[:object_id]).map(&:user)
    if mention_users.present?

      # only notify if read permission on group are given
      mention_users.each do |mention_user|
        next if !mention_user.group_access?(ticket.group_id, 'read')

        possible_recipients.push mention_user
        @recipients_reason[mention_user.id] = __('You are receiving this because you were mentioned in this ticket.')
      end
    end

    # apply owner
    if ticket.owner_id != 1
      possible_recipients.push ticket.owner
      @recipients_reason[ticket.owner_id] = __('You are receiving this because you are a member of the group of this ticket.')
    end

    # apply ticket customer
    if ticket.customer_id && ticket.customer_id != 1
      customer = User.find_by(id: ticket.customer_id)
      if customer&.active? && possible_recipients.exclude?(customer)
        possible_recipients.push customer
        @recipients_reason[ticket.customer_id] = __('You are receiving this because you are a member of the group of this ticket.')
      end
    end

    # apply out of office agents
    possible_recipients_additions = Set.new
    possible_recipients.each do |user|
      ooo_replacements(
        user:         user,
        replacements: possible_recipients_additions,
        reasons:      recipients_reason,
        ticket:       ticket,
      )
    end

    if possible_recipients_additions.present?
      # join unique entries
      possible_recipients |= possible_recipients_additions.to_a
    end

    recipients_reason_by_notifications_settings(possible_recipients)

    # Only notify shared customers for actual ticket updates (comments, field changes)
    # Exclude internal operational events (create, reminders, escalations)
    add_shared_access_recipients if @item[:type] == 'update'
  end

  def add_shared_access_recipients
    shared_users = Ticket::SharedAccess.where(ticket_id: ticket.id).includes(:user).map(&:user)
    already_added_ids = @recipients_and_channels.to_set { |r| r[:user].id }

    shared_users.each do |shared_user|
      next if already_added_ids.include?(shared_user.id)
      next if !shared_user.active?

      # Check user's notification preferences
      result = NotificationFactory::Mailer.notification_settings(shared_user, ticket, @item[:type])

      # If no preferences configured, default to allowing notifications
      # (shared access is an explicit opt-in, so notifications are expected)
      if !result
        result = {
          user:     shared_user,
          channels: { 'online' => true, 'email' => true },
        }
      end

      @recipients_and_channels.push(result)
      @recipients_reason[shared_user.id] = __('You are receiving this because this ticket was shared with you.')
    end
  end

  def recipients_reason_by_notifications_settings(possible_recipients)
    already_checked_recipient_ids = {}
    possible_recipients.each do |user|
      result = NotificationFactory::Mailer.notification_settings(user, ticket, @item[:type])

      # If no preferences configured and user is a customer, default to allowing notifications
      if !result && customer?(user)
        result = {
          user:     user,
          channels: { 'online' => true, 'email' => true },
        }
      end

      next if !result
      next if already_checked_recipient_ids[user.id]

      already_checked_recipient_ids[user.id] = true
      @recipients_and_channels.push result
      next if recipients_reason[user.id]

      @recipients_reason[user.id] = __('You are receiving this because you are a member of the group of this ticket.')
    end
  end

  def recipient_myself?(user)
    return false if @params[:interface_handle] != 'application_server'

    if @item[:type] == 'create' && user.id == ticket.customer_id
      return false
    end

    return true if article&.updated_by_id == user.id
    return true if !article && @item[:user_id] == user.id

    false
  end

  def send_assignment_notification_with_cc
    return if recipients_and_channels.blank?

    # Find the owner (To:) and others (CC:)
    owner = ticket.owner
    owner_recipient = recipients_and_channels.find { |r| r[:user].id == owner.id }

    # If owner is not in recipients, something went wrong
    return if !owner_recipient

    # Collect CC recipients (customer + shared customers)
    cc_recipients = recipients_and_channels.reject { |r| r[:user].id == owner.id }

    # Send online notifications to all recipients
    recipients_and_channels.each do |recipient_settings|
      user = recipient_settings[:user]
      next if !recipient_settings[:channels]['online']

      send_to_single_recipient_online(user, ticket, article)
    end

    # Build CC list - only agents with full group access (NOT customers or shared customers)
    # Per spec: assignment emails go to the new owner (To:) and full-group-access agents only.
    # Customers and shared customers must NOT receive assignment notifications.
    cc_recipients_who_want_email = cc_recipients.reject { |r| customer?(r[:user]) }.select do |r|
      r[:channels] && r[:channels]['email']
    end

    cc_emails = cc_recipients_who_want_email
      .filter_map { |r| r[:user].email }
      .join(', ')

    # Get template and objects
    changes = @item[:changes] || {}
    template = 'ticket_assigned'

    attachments = []
    if article
      attachments = article.attachments_inline
    end

    # Build email body
    result = NotificationFactory::Mailer.template(
      template:   template,
      locale:     owner.preferences[:locale] || Locale.default,
      objects:    {
        ticket:       ticket,
        article:      article,
        recipient:    owner,
        current_user: current_user,
        changes:      changes,
        reason:       recipients_reason[owner.id],
      },
      standalone: false,
    )

    # Rebuild subject if needed
    if ticket.respond_to?(:subject_build)
      result[:subject] = ticket.subject_build(result[:subject])
    end

    # Prepare body
    if result[:body]
      result[:body] = HtmlSanitizer.adjust_inline_image_size(result[:body])
      result[:body] = HtmlSanitizer.dynamic_image_size(result[:body])
    end

    # Send one email with CC (always send, even if owner has no notification preferences)
    NotificationFactory::Mailer.deliver(
      recipient:    owner,
      subject:      result[:subject],
      body:         result[:body],
      content_type: 'text/html',
      message_id:   "<notification.#{DateTime.current.to_fs(:number)}.#{ticket.id}.#{owner.id}.#{SecureRandom.uuid}@#{Setting.get('fqdn')}>",
      references:   ticket.get_references,
      attachments:  attachments,
      cc:           cc_emails.presence,
    )

    # Add notification history for owner
    add_recipient_list_to_history(ticket, owner, ['email'], 'update')

    # Add notification history for CC recipients
    cc_recipients_who_want_email.each do |r|
      add_recipient_list_to_history(ticket, r[:user], ['email'], 'update')
    end

  end

  def send_creation_notification_with_cc
    return if recipients_and_channels.blank?

    # Find the customer (To:) and agents (CC:)
    customer = ticket.customer
    customer_recipient = recipients_and_channels.find { |r| r[:user].id == customer.id }

    # If customer is not in recipients, something went wrong
    if !customer_recipient
      return
    end

    # Collect CC recipients (agents with full permission)
    cc_recipients = recipients_and_channels.reject { |r| r[:user].id == customer.id }

    # Send online notifications to all recipients
    recipients_and_channels.each do |recipient_settings|
      user = recipient_settings[:user]
      next if !recipient_settings[:channels]['online']

      send_to_single_recipient_online(user, ticket, article)
    end

    # Build CC list from recipients who want email
    cc_recipients_who_want_email = cc_recipients.select { |r| r[:channels]['email'] }

    cc_emails = cc_recipients_who_want_email
      .filter_map { |r| r[:user].email }
      .join(', ')

    # Get template and objects
    template = 'ticket_create'

    attachments = []
    if article
      attachments = article.attachments_inline
    end

    # Build email body
    result = NotificationFactory::Mailer.template(
      template:   template,
      locale:     customer.preferences[:locale] || Locale.default,
      objects:    {
        ticket:       ticket,
        article:      article,
        recipient:    customer,
        current_user: current_user,
        changes:      {},
        reason:       recipients_reason[customer.id],
      },
      standalone: false,
    )

    # Rebuild subject if needed
    if ticket.respond_to?(:subject_build)
      result[:subject] = ticket.subject_build(result[:subject])
    end

    # Prepare body
    if result[:body]
      result[:body] = HtmlSanitizer.adjust_inline_image_size(result[:body])
      result[:body] = HtmlSanitizer.dynamic_image_size(result[:body])
    end

    # Send one email with CC — skip if customer has opted out of email notifications
    if customer_email_notifications_enabled?(customer)
      NotificationFactory::Mailer.deliver(
        recipient:    customer,
        subject:      result[:subject],
        body:         result[:body],
        content_type: 'text/html',
        message_id:   "<notification.#{DateTime.current.to_fs(:number)}.#{ticket.id}.#{customer.id}.#{SecureRandom.uuid}@#{Setting.get('fqdn')}>",
        references:   ticket.get_references,
        attachments:  attachments,
        cc:           cc_emails.presence,
      )

      # Add notification history for customer
      add_recipient_list_to_history(ticket, customer, ['email'], 'create')
    end

    # Add notification history for CC recipients
    cc_recipients_who_want_email.each do |r|
      add_recipient_list_to_history(ticket, r[:user], ['email'], 'create')
    end

  end

  def send_state_change_notification_with_cc
    return if recipients_and_channels.blank?

    # Find the customer (To:) and others (CC:)
    customer = ticket.customer
    customer_recipient = recipients_and_channels.find { |r| r[:user].id == customer.id }

    # If customer is not in recipients, something went wrong
    if !customer_recipient
      return
    end

    # Collect CC recipients (shared customers + agents with full access)
    cc_recipients = recipients_and_channels.reject { |r| r[:user].id == customer.id || r[:user].id == current_user.id }

    # Send online notifications to all recipients
    recipients_and_channels.each do |recipient_settings|
      user = recipient_settings[:user]
      next if !recipient_settings[:channels]['online']

      send_to_single_recipient_online(user, ticket, article)
    end

    # Build CC list — ticket creator always gets email; shared customers respect
    # their preference; agents/legal admins check their notification settings
    cc_recipients_who_want_email = cc_recipients.select do |r|
      user = r[:user]
      if user.id == ticket.customer_id
        # Ticket creator always receives — cannot opt out of their own ticket
        user.email.present?
      elsif customer?(user)
        # Shared customer — respect their email notification preference
        customer_email_notifications_enabled?(user)
      else
        # Agents/legal admins — check their notification preferences
        r[:channels] && r[:channels]['email']
      end
    end

    cc_emails = cc_recipients_who_want_email
      .filter_map { |r| r[:user].email }
      .join(', ')

    # Get template and objects
    changes = @item[:changes] || {}
    # Remove owner_id from changes when determining template, so it focuses on state change
    state_only_changes = changes.except('owner_id')
    template = determine_update_template(ticket, article, state_only_changes)

    attachments = []
    if article
      attachments = article.attachments_inline
    end

    # Build email body
    result = NotificationFactory::Mailer.template(
      template:   template,
      locale:     customer.preferences[:locale] || Locale.default,
      objects:    {
        ticket:       ticket,
        article:      article,
        recipient:    customer,
        current_user: current_user,
        changes:      changes,
        reason:       recipients_reason[customer.id],
      },
      standalone: false,
    )

    # Rebuild subject if needed
    if ticket.respond_to?(:subject_build)
      result[:subject] = ticket.subject_build(result[:subject])
    end

    # Prepare body
    if result[:body]
      result[:body] = HtmlSanitizer.adjust_inline_image_size(result[:body])
      result[:body] = HtmlSanitizer.dynamic_image_size(result[:body])
    end

    # Send one email with CC — skip if customer has opted out of email notifications
    if customer_email_notifications_enabled?(customer)
      NotificationFactory::Mailer.deliver(
        recipient:    customer,
        subject:      result[:subject],
        body:         result[:body],
        content_type: 'text/html',
        message_id:   "<notification.#{DateTime.current.to_fs(:number)}.#{ticket.id}.#{customer.id}.#{SecureRandom.uuid}@#{Setting.get('fqdn')}>",
        references:   ticket.get_references,
        attachments:  attachments,
        cc:           cc_emails.presence,
      )

      # Add notification history for customer
      add_recipient_list_to_history(ticket, customer, ['email'], 'update')
    end

    # Add notification history for CC recipients
    cc_recipients_who_want_email.each do |r|
      add_recipient_list_to_history(ticket, r[:user], ['email'], 'update')
    end

  end

  def send_comment_notification_with_cc(article)
    ticket = article.ticket
    commenter = article.created_by
    ticket_owner = ticket.owner_id == 1 ? nil : ticket.owner
    ticket_creator = ticket.customer

    # Get all legal admins (agents with full group access)
    all_agents_with_full_access = User.group_access(ticket.group_id, 'full')
      .select { |u| u.active? && u.permissions?('ticket.agent') }

    # Get all shared customers
    shared_customers = ticket.shared_accesses.includes(:user).map(&:user).select(&:active?)

    # Determine primary recipient (To:) and CC based on who commented
    primary_recipient = nil
    cc_user_list = []

    # Case 1: Ticket creator comments
    if commenter.id == ticket_creator.id
      # To: Owner of ticket
      primary_recipient = ticket_owner
      # CC: Legal admins + Shared customers
      cc_user_list = all_agents_with_full_access + shared_customers

    # Case 2: Shared customer comments
    elsif shared_customers.any? { |sc| sc.id == commenter.id }
      # To: Owner of ticket
      primary_recipient = ticket_owner
      # CC: Legal admins + Other shared customers + Ticket creator
      cc_user_list = all_agents_with_full_access + shared_customers.reject { |sc| sc.id == commenter.id }
      cc_user_list << ticket_creator if ticket_creator && ticket_creator.id != commenter.id

    # Case 3: Owner of ticket comments
    elsif ticket_owner && commenter.id == ticket_owner.id
      # To: Ticket creator
      primary_recipient = ticket_creator
      # CC: Shared customers + Legal admins
      cc_user_list = shared_customers + all_agents_with_full_access.reject { |a| a.id == commenter.id }

    # Case 4: Legal admin comments
    elsif all_agents_with_full_access.any? { |a| a.id == commenter.id }
      # To: Ticket creator
      primary_recipient = ticket_creator
      # CC: Shared customers + Other legal admins (excluding commenter)
      cc_user_list = shared_customers + all_agents_with_full_access.reject { |a| a.id == commenter.id }
      cc_user_list << ticket_owner if ticket_owner && ticket_owner.id != commenter.id && cc_user_list.exclude?(ticket_owner)
    end

    # If no primary recipient, fallback to standard flow
    return if !primary_recipient || !primary_recipient.active?

    # Remove commenter and primary recipient from CC list
    cc_user_list = cc_user_list.uniq.reject { |u| u.id == commenter.id || u.id == primary_recipient.id }

    # Filter CC recipients who want email notifications
    # Ticket creator always gets email; shared customers respect their preference;
    # agents/legal admins check their notification settings
    cc_recipients = cc_user_list.select do |u|
      if u.id == ticket_creator.id
        # Ticket creator always receives — cannot opt out of their own ticket
        u.email.present?
      elsif shared_customers.include?(u)
        # Shared customer — respect their email notification preference
        customer_email_notifications_enabled?(u)
      else
        # Agents/legal admins — check their notification preferences
        can_receive_notification?(u, 'email')
      end
    end

    # Send in-app notifications to all (primary + CC)
    [primary_recipient, *cc_recipients].each do |user|
      send_to_single_recipient_online(user, ticket, article)
    end

    # Check if primary recipient wants email.
    # Ticket creator always receives — cannot opt out of their own ticket.
    # Shared customers respect their preference. Agents check notification settings.
    if primary_recipient.id == ticket_creator.id
      return if primary_recipient.email.blank?
    elsif customer?(primary_recipient)
      return if !customer_email_notifications_enabled?(primary_recipient)
    elsif !can_receive_notification?(primary_recipient, 'email')
      return
    end

    # Build CC emails
    cc_emails = cc_recipients
      .map { |u| "#{u.firstname} #{u.lastname} <#{u.email}>" }
      .join(', ')

    # Get attachments
    attachments = article.attachments_inline || []

    # Build email
    result = NotificationFactory::Mailer.template(
      template:   'ticket_comment_added',
      locale:     primary_recipient.preferences[:locale] || Locale.default,
      objects:    {
        ticket:       ticket,
        article:      article,
        recipient:    primary_recipient,
        current_user: commenter,
        commenter:    commenter,
      },
      standalone: false,
    )

    # Rebuild subject if needed
    if ticket.respond_to?(:subject_build)
      result[:subject] = ticket.subject_build(result[:subject])
    end

    # Prepare body
    if result[:body]
      result[:body] = HtmlSanitizer.adjust_inline_image_size(result[:body])
      result[:body] = HtmlSanitizer.dynamic_image_size(result[:body])
    end

    # Send email with CC
    NotificationFactory::Mailer.deliver(
      recipient:    primary_recipient,
      subject:      result[:subject],
      body:         result[:body],
      content_type: 'text/html',
      message_id:   "<notification.comment.#{DateTime.current.to_fs(:number)}.#{ticket.id}.#{primary_recipient.id}.#{SecureRandom.uuid}@#{Setting.get('fqdn')}>",
      references:   ticket.get_references,
      attachments:  attachments,
      cc:           cc_emails.presence,
    )

    # Add notification history
    add_recipient_list_to_history(ticket, primary_recipient, ['email'], 'update')
    cc_recipients.each do |cc_user|
      add_recipient_list_to_history(ticket, cc_user, ['email'], 'update')
    end

  end

  def send_under_legal_review_notification_with_cc
    return if recipients_and_channels.blank?

    # Determine primary recipient (To:)
    # Primary is the ticket owner (who will be assigned to work on it)
    owner = ticket.owner_id == 1 ? nil : ticket.owner
    primary_recipient = owner || ticket.customer

    primary_recipient_settings = recipients_and_channels.find { |r| r[:user].id == primary_recipient.id }
    return if !primary_recipient_settings

    # Get who made the change
    changer = User.find_by(id: @item[:user_id])

    # Build CC list:
    # - All legal admins (users with "full" group access)
    # - All shared customers
    # BUT exclude:
    # - The person who made the change (changer)
    # - The primary recipient (they're in To)

    all_agents_with_full_access = User.group_access(ticket.group_id, 'full')
      .select { |u| u.active? && u.permissions?('ticket.agent') }

    shared_customers = ticket.shared_accesses.includes(:user).map(&:user).select(&:active?)

    # If ticket creator made the change, include all shared customers in CC
    # If shared customer made the change, include ticket creator + other shared customers in CC
    cc_user_list = []

    # Add legal admins
    all_agents_with_full_access.each do |agent|
      next if changer && agent.id == changer.id # Don't include who made the change
      next if agent.id == primary_recipient.id # Don't include primary recipient

      cc_user_list << agent
    end

    # Add shared customers
    shared_customers.each do |shared_customer|
      next if changer && shared_customer.id == changer.id # Don't include who made the change
      next if shared_customer.id == primary_recipient.id # Don't include primary recipient

      cc_user_list << shared_customer
    end

    # Add ticket creator if not already included
    if ticket.customer && ticket.customer.id != primary_recipient.id && (!changer || ticket.customer.id != changer.id)
      cc_user_list << ticket.customer
    end

    # Remove duplicates
    cc_user_list = cc_user_list.uniq

    # Send online notifications to all
    recipients_and_channels.each do |recipient_settings|
      user = recipient_settings[:user]
      next if !recipient_settings[:channels]['online']

      send_to_single_recipient_online(user, ticket, article)
    end

    # Build CC list — ticket creator always gets email; shared customers respect
    # their preference; agents/legal admins check their notification settings
    cc_recipients_who_want_email = cc_user_list.select do |user|
      if user.id == ticket.customer_id
        # Ticket creator always receives — cannot opt out of their own ticket
        user.email.present?
      elsif customer?(user)
        # Shared customer — respect their email notification preference
        customer_email_notifications_enabled?(user)
      else
        # Agents/legal admins — check their notification preferences
        recipient_setting = recipients_and_channels.find { |r| r[:user].id == user.id }
        recipient_setting && recipient_setting[:channels] && recipient_setting[:channels]['email']
      end
    end

    cc_emails = cc_recipients_who_want_email
      .map { |u| "#{u.firstname} #{u.lastname} <#{u.email}>" }
      .join(', ')

    # Get template and objects
    changes = @item[:changes] || {}
    # Remove owner_id from changes when determining template, so it focuses on state change
    state_only_changes = changes.except('owner_id')
    template = determine_update_template(ticket, article, state_only_changes)

    attachments = []
    if article
      attachments = article.attachments_inline
    end

    # Build email body
    result = NotificationFactory::Mailer.template(
      template:   template,
      locale:     primary_recipient.preferences[:locale] || Locale.default,
      objects:    {
        ticket:       ticket,
        article:      article,
        recipient:    primary_recipient,
        current_user: current_user,
        changes:      changes,
        reason:       recipients_reason[primary_recipient.id],
      },
      standalone: false,
    )

    # Rebuild subject if needed
    if ticket.respond_to?(:subject_build)
      result[:subject] = ticket.subject_build(result[:subject])
    end

    # Prepare body
    if result[:body]
      result[:body] = HtmlSanitizer.adjust_inline_image_size(result[:body])
      result[:body] = HtmlSanitizer.dynamic_image_size(result[:body])
    end

    # Send one email with CC.
    # Primary recipient is the ticket owner (agent) or, if unassigned, the ticket customer.
    # When it is the ticket customer, they are the ticket creator — always send.
    # When it is a shared customer (edge case), respect their preference.
    if shared_customer_only?(primary_recipient) && !customer_email_notifications_enabled?(primary_recipient)
      # Shared customer who has opted out — skip email
    else
      NotificationFactory::Mailer.deliver(
        recipient:    primary_recipient,
        subject:      result[:subject],
        body:         result[:body],
        content_type: 'text/html',
        message_id:   "<notification.#{DateTime.current.to_fs(:number)}.#{ticket.id}.#{primary_recipient.id}.#{SecureRandom.uuid}@#{Setting.get('fqdn')}>",
        references:   ticket.get_references,
        attachments:  attachments,
        cc:           cc_emails.presence,
      )

      # Add notification history
      add_recipient_list_to_history(ticket, primary_recipient, ['email'], 'update')
    end

    # Add notification history for CC recipients
    cc_recipients_who_want_email.each do |user|
      add_recipient_list_to_history(ticket, user, ['email'], 'update')
    end

  end

  def send_internal_comment_notification(article)
    ticket = article.ticket
    commenter = article.created_by
    assigned_owner = ticket.owner_id == 1 ? nil : ticket.owner

    # Get all agents with full group access (legal admins, system admins, agents with full permission)
    all_agents_with_full_access = User.group_access(ticket.group_id, 'full')
      .select { |u| u.active? && u.permissions?('ticket.agent') }

    # Determine recipients based on who commented
    to_recipients = []
    cc_recipients = []

    if assigned_owner && commenter.id == assigned_owner.id
      # Case 1: Assigned owner commented → Send one email to ALL legal admins (grouped in To:)
      all_agents_with_full_access.each do |agent|
        if agent.id == commenter.id
          next
        end

        can_receive = can_receive_notification?(agent, 'email')

        if can_receive
          to_recipients << agent
        end
      end

      # If no valid recipients, return early
      if to_recipients.empty?
        return
      end

      # Send one email with all legal admins in To: field
      # Use the first recipient as primary for template rendering
      primary_recipient = to_recipients.first

      # Build To: list with all legal admins
      to_emails = to_recipients
        .map { |u| "#{u.firstname} #{u.lastname} <#{u.email}>" }
        .join(', ')

      send_internal_comment_email_to_multiple(ticket, article, commenter, to_recipients, to_emails)

      # Add notification history and in-app notifications for all recipients
      to_recipients.each do |recipient|
        add_recipient_list_to_history(ticket, recipient, ['email'], 'update')
        send_to_single_recipient_online(recipient, ticket, article)
      end
    else
      # Case 2: Legal admin (or other agent with full access) commented
      # To: Assigned owner, CC: All other legal admins
      primary_recipient = nil

      if assigned_owner && assigned_owner.id != commenter.id && can_receive_notification?(assigned_owner, 'email')
        primary_recipient = assigned_owner
      end

      all_agents_with_full_access.each do |agent|
        if agent.id == commenter.id
          next
        end

        if assigned_owner && agent.id == assigned_owner.id
          next
        end

        can_receive = can_receive_notification?(agent, 'email')

        if !can_receive
          next
        end

        if primary_recipient.nil?
          primary_recipient = agent
        else
          cc_recipients << agent
        end
      end

      # If no valid recipients, return early
      if primary_recipient.nil?
        return
      end

      # Prepare CC emails
      cc_emails = cc_recipients
        .map { |u| "#{u.firstname} #{u.lastname} <#{u.email}>" }
        .join(', ')

      # Send one email with CC
      send_internal_comment_email(ticket, article, commenter, primary_recipient, cc_emails)

      # Add notification history for CC recipients
      # rubocop:disable Style/CombinableLoops
      cc_recipients.each do |cc_user|
        add_recipient_list_to_history(ticket, cc_user, ['email'], 'update')
      end

      # Send in-app notifications to CC recipients
      cc_recipients.each do |user|
        send_to_single_recipient_online(user, ticket, article)
      end
      # rubocop:enable Style/CombinableLoops
    end
  end

  def send_internal_comment_email(ticket, article, commenter, recipient, cc_emails)

    # Get attachments
    attachments = article.attachments_inline || []

    # Build email
    result = NotificationFactory::Mailer.template(
      template:   'ticket_internal_comment',
      locale:     recipient.preferences[:locale] || Locale.default,
      objects:    {
        ticket:    ticket,
        article:   article,
        recipient: recipient,
        commenter: commenter,
      },
      standalone: false,
    )

    # Rebuild subject if needed
    if ticket.respond_to?(:subject_build)
      result[:subject] = ticket.subject_build(result[:subject])
    end

    # Prepare body
    if result[:body]
      result[:body] = HtmlSanitizer.adjust_inline_image_size(result[:body])
      result[:body] = HtmlSanitizer.dynamic_image_size(result[:body])
    end

    # Send email
    NotificationFactory::Mailer.deliver(
      recipient:    recipient,
      subject:      result[:subject],
      body:         result[:body],
      content_type: 'text/html',
      message_id:   "<notification.internal.#{DateTime.current.to_fs(:number)}.#{ticket.id}.#{recipient.id}.#{SecureRandom.uuid}@#{Setting.get('fqdn')}>",
      references:   ticket.get_references,
      attachments:  attachments,
      cc:           cc_emails.presence,
    )

    # Add notification history
    add_recipient_list_to_history(ticket, recipient, ['email'], 'update')

    # Send in-app notification
    send_to_single_recipient_online(recipient, ticket, article)

  end

  def send_internal_comment_email_to_multiple(ticket, article, commenter, recipients, to_emails)

    # Get attachments
    attachments = article.attachments_inline || []

    # Use first recipient for template rendering (all will see the same content)
    primary_recipient = recipients.first

    # Build email
    result = NotificationFactory::Mailer.template(
      template:   'ticket_internal_comment',
      locale:     primary_recipient.preferences[:locale] || Locale.default,
      objects:    {
        ticket:    ticket,
        article:   article,
        recipient: primary_recipient,
        commenter: commenter,
      },
      standalone: false,
    )

    # Rebuild subject if needed
    if ticket.respond_to?(:subject_build)
      result[:subject] = ticket.subject_build(result[:subject])
    end

    # Prepare body
    if result[:body]
      result[:body] = HtmlSanitizer.adjust_inline_image_size(result[:body])
      result[:body] = HtmlSanitizer.dynamic_image_size(result[:body])
    end

    # Send email with all recipients in To: field
    NotificationFactory::Mailer.deliver(
      recipient:    primary_recipient,
      to:           to_emails,
      subject:      result[:subject],
      body:         result[:body],
      content_type: 'text/html',
      message_id:   "<notification.internal.#{DateTime.current.to_fs(:number)}.#{ticket.id}.#{SecureRandom.uuid}@#{Setting.get('fqdn')}>",
      references:   ticket.get_references,
      attachments:  attachments,
    )

  end

  def can_receive_notification?(user, channel)
    return false if !user.active?

    if channel == 'email' && user.email.blank?
      return false
    end

    # Check user's notification preferences
    NotificationFactory::Mailer.notification_settings(user, ticket, @item[:type])
  end

  # Returns true when the user should receive email for this ticket.
  #
  # Rule: ticket creators always receive email (cannot opt out of their own ticket).
  # Shared customers (added via Ticket::SharedAccess) can opt out via their
  # email_notifications_enabled preference. Agents are not affected by this method.
  def customer_email_notifications_enabled?(user)
    return false if user.email.blank?

    # Ticket creator always receives — preference does not apply to their own tickets.
    return true if user.id == ticket.customer_id

    # Shared customer — respect their preference (default: true).
    user.shared_ticket_email_notifications_enabled?
  end

  # Returns true if the user is a shared customer on this ticket but is NOT
  # the ticket creator. Used to decide whether to show the unsubscribe link
  # (ticket creators cannot unsubscribe from their own tickets).
  def shared_customer_only?(user)
    return false if user.id == ticket.customer_id

    Ticket::SharedAccess.exists?(ticket_id: ticket.id, user_id: user.id)
  end

  def customer?(user)
    # Check if user is the ticket creator or a shared customer
    return true if user.id == ticket.customer_id

    Ticket::SharedAccess.exists?(ticket_id: ticket.id, user_id: user.id)
  end

  def send_to_single_recipient(recipient_settings)
    user     = recipient_settings[:user]
    channels = recipient_settings[:channels]

    # ignore user who changed it by him self via web
    return if recipient_myself?(user)

    # ignore inactive users
    return if !user.active?

    blocked_in_days = user.mail_delivery_failed_blocked_days
    if blocked_in_days.positive?
      Rails.logger.info "Send no system notifications to #{user.email} because email is marked as mail_delivery_failed for #{blocked_in_days} day(s)"
      return
    end

    # ignore if no changes has been done
    changes = human_changes(@item[:changes], ticket, user)
    return if @item[:type] == 'update' && !article && changes.blank?

    # check if today already notified
    if %w[reminder_reached escalation escalation_warning].include?(@item[:type]) && !Ticket::DailyEventLock.lock!(
      lock_type:      'notification',
      lock_activator: @item[:type],
      ticket:,
      related_object: user,
    )
      return
    end

    # create online notification
    used_channels = []

    if channels['online']
      used_channels.push 'online'

      send_to_single_recipient_online(user, ticket, article)
    end

    if channels['email'] && user.email.present?
      used_channels.push 'email'

      send_to_single_recipient_email(user, ticket, article, changes)
    end

    add_recipient_list_to_history(ticket, user, used_channels, @item[:type])
  end

  def add_recipient_list_to_history(ticket, user, channels, type)
    return if channels.blank?

    identifier     = user.email.presence || user.login
    recipient_list = "#{identifier}(#{type}:#{channels.join(',')})"

    History.add(
      o_id:           ticket.id,
      history_type:   'notification',
      history_object: 'Ticket',
      value_to:       recipient_list,
      created_by_id:  @item[:user_id] || 1
    )
  end

  private

  def ooo_replacements(user:, replacements:, ticket:, reasons:)
    replacement = user.out_of_office_agent

    return if !replacement

    return if !TicketPolicy.new(replacement, ticket).agent_read_access?

    return if !replacements.add?(replacement)

    reasons[replacement.id] = __('You are receiving this because you are out-of-office replacement for a participant of this ticket.')
  end

  def possible_recipients_of_group(group_id)
    Rails.cache.fetch("User/notification/possible_recipients_of_group/#{group_id}/#{User.latest_change}", expires_in: 20.seconds) do
      User.group_access(group_id, 'full').sort_by(&:login)
    end
  end

  def send_to_single_recipient_online(user, ticket, article)
    created_by_id = @item[:user_id] || 1

    # delete old notifications
    if @item[:type] == 'reminder_reached'
      seen = false
      created_by_id = 1
      OnlineNotification.remove_by_type('Ticket', ticket.id, @item[:type], user)

    elsif %w[escalation escalation_warning].include?(@item[:type])
      seen = false
      created_by_id = 1
      OnlineNotification.remove_by_type('Ticket', ticket.id, 'escalation', user)
      OnlineNotification.remove_by_type('Ticket', ticket.id, 'escalation_warning', user)

    # on updates without state changes create unseen messages
    elsif @item[:type] != 'create' && (@item[:changes].blank? || @item[:changes]['state_id'].blank?)
      seen = false
    else
      seen = OnlineNotification.seen_state?(ticket, user.id)
    end

    OnlineNotification.add(
      type:          @item[:type],
      object:        @item[:object],
      o_id:          @item[:object].eql?('Ticket') ? ticket.id : article.id,
      seen:          seen,
      created_by_id: created_by_id,
      user_id:       user.id,
    )
  end

  def send_to_single_recipient_email(user, ticket, article, changes)
    # get user based notification template
    # if create, send create message / block update messages
    template = case @item[:type]
               when 'create'
                 'ticket_create'
               when 'update'
                 determine_update_template(ticket, article, changes)
               when 'reminder_reached'
                 'ticket_reminder_reached'
               when 'escalation'
                 'ticket_escalation'
               when 'escalation_warning'
                 'ticket_escalation_warning'
               when 'update.merged_into'
                 'ticket_update_merged_into'
               when 'update.received_merge'
                 'ticket_update_received_merge'
               when 'update.reaction'
                 'ticket_article_update_reaction'
               else
                 raise "unknown type for notification #{@item[:type]}"
               end

    attachments = []
    if article
      attachments = article.attachments_inline
    end
    NotificationFactory::Mailer.notification(
      template:    template,
      user:        user,
      objects:     {
        ticket:       ticket,
        article:      article,
        recipient:    user,
        current_user: current_user,
        changes:      changes,
        reason:       recipients_reason[user.id],
      },
      message_id:  "<notification.#{DateTime.current.to_fs(:number)}.#{ticket.id}.#{user.id}.#{SecureRandom.uuid}@#{Setting.get('fqdn')}>",
      references:  ticket.get_references,
      main_object: ticket,
      attachments: attachments,
    )
  end

  def determine_update_template(_ticket, article, changes)
    # Priority order matters - check most specific conditions first

    # 1. Ownership/Assignment changed (check before article to avoid false positive)
    return 'ticket_assigned' if changes&.key?('owner_id')

    # 2. Comment/Article added
    return 'ticket_comment_added' if article

    # 3. State changed to specific values
    if changes&.key?('state_id')
      new_state_id = changes['state_id'].last
      old_state_id = changes['state_id'].first

      # Get the new state name for specific template matching
      new_state = Ticket::State.find_by(id: new_state_id)

      # Custom Legal Intake states
      if new_state && new_state.name == 'under_legal_review'
        return 'ticket_state_under_legal_review'
      elsif new_state && new_state.name == 'awaiting_response'
        return 'ticket_state_awaiting_response'
      elsif new_state && new_state.name == 'ready_for_signature'
        return 'ticket_state_ready_for_signature'
      elsif new_state && new_state.name == 'sent_for_signature'
        return 'ticket_state_sent_for_signature'
      elsif new_state && new_state.name == 'signed'
        return 'ticket_state_signed'
      elsif new_state && new_state.name == 'resolved'
        return 'ticket_state_resolved'
      elsif new_state && new_state.name == 'closed'
        return 'ticket_state_closed'
      end

      # Check if changed to other resolved-type states (merged, removed)
      resolved_type_states = Ticket::State.where(name: %w[merged removed]).pluck(:id)
      return 'ticket_state_resolved' if resolved_type_states.include?(new_state_id)

      # Check if reopened (from any closed/resolved state to open)
      all_closed_states = Ticket::State.where(name: %w[closed merged removed resolved]).pluck(:id)
      open_states = Ticket::State.where(name: %w[new open]).pluck(:id)
      return 'ticket_state_reopened' if all_closed_states.include?(old_state_id) && open_states.include?(new_state_id)

      # Other state changes
      return 'ticket_state_changed'
    end

    # 4. Priority changed
    return 'ticket_priority_changed' if changes&.key?('priority_id')

    # 5. Fallback for any other updates
    'ticket_update'
  end

  def reopened_state?(_ticket, changes)
    return false if !changes&.key?('state_id')

    old_state_id = changes['state_id'].first
    new_state_id = changes['state_id'].last

    resolved_states = Ticket::State.where(name: %w[closed merged removed resolved]).pluck(:id)
    open_states = Ticket::State.where(name: %w[new open]).pluck(:id)

    resolved_states.include?(old_state_id) && open_states.include?(new_state_id)
  end
end

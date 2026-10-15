// Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

import type { AvatarMenuPlugin } from './index.ts'

// Trilogy: opens the Legal Intake attention dashboard. Host mapping matches
// the legacy UI's navigation item (legal_intake_dashboard_link.coffee).
const legalIntakeDashboardUrl = () => {
  const { host } = window.location
  if (host.startsWith('staging-tickets.'))
    return `https://staging.${host.slice('staging-tickets.'.length)}/dashboard`
  if (host.startsWith('tickets.')) return `https://${host.slice('tickets.'.length)}/dashboard`
  return 'https://localhost:3000/dashboard'
}

export default <AvatarMenuPlugin>{
  key: 'legal-intake-dashboard',
  label: __('Ticket dashboard'),
  permission: ['ticket.agent', 'ticket.customer'],
  link: legalIntakeDashboardUrl(),
  linkExternal: true,
  openInNewTab: true,
  icon: 'speedometer2',
  order: 75,
}

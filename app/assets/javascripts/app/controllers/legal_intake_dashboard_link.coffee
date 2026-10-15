# Trilogy: a "Ticket Dashboard" item in the left navigation that opens the
# Legal Intake attention dashboard (where each ticket stands, whose move it is,
# escalations) in a new tab. The app host is derived from this Zammad's host:
#   tickets.<domain>          -> <domain>           (production)
#   staging-tickets.<domain>  -> staging.<domain>   (staging)
#   anything else             -> https://localhost:3000 (local dev)
App.LegalIntakeDashboardUrl = ->
  host = window.location.host
  if /^staging-tickets\./.test(host)
    return "https://#{host.replace(/^staging-tickets\./, 'staging.')}/dashboard"
  if /^tickets\./.test(host)
    return "https://#{host.replace(/^tickets\./, '')}/dashboard"
  'https://localhost:3000/dashboard'

App.Config.set('LegalIntakeDashboard', {
  prio: 150,
  parent: '',
  name: __('Ticket Dashboard'),
  target: App.LegalIntakeDashboardUrl(),
  key: 'LegalIntakeDashboard',
  permission: ['ticket.agent', 'ticket.customer'],
  class: 'stopwatch',
  external: true
}, 'NavBar')

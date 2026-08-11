# Repoint the three li_* external-source fields' search_url to a new intake
# base URL (e.g. localhost:3002 -> localhost:3000), WITHOUT touching the column
# (data already migrated to jsonb). Config-only update.
#
#   INTAKE_LOOKUP_URL=https://localhost:3000/api/v1/zammad/lookup \
#   INTAKE_LOOKUP_TOKEN=sk-... \
#   bundle exec rails runner scripts/li_external_source_repoint.rb

intake_url   = ENV.fetch('INTAKE_LOOKUP_URL')  { abort 'INTAKE_LOOKUP_URL required' }.sub(%r{/+$}, '')
intake_token = ENV.fetch('INTAKE_LOOKUP_TOKEN') { abort 'INTAKE_LOOKUP_TOKEN required' }

FIELDS = {
  'li_legal_entity'  => { type: 'legal_entity',  extra: '' },
  'li_business_unit' => { type: 'business_unit', extra: '' },
  'li_product'       => { type: 'product',       extra: '&business_unit=#{ticket.li_business_unit}' },
}.freeze

FIELDS.each do |name, cfg|
  attr = ObjectManager::Attribute.find_by(name: name, object_lookup_id: ObjectLookup.by_name('Ticket'))
  abort "attribute #{name} not found" unless attr

  new_option = attr.data_option.deep_dup
  new_option['search_url'] = "#{intake_url}?type=#{cfg[:type]}&query=#{'#{search.term}'}&limit=40#{cfg[:extra]}"
  new_option['bearer_token_auth'] = intake_token
  # Local dev intake uses a self-signed HTTPS cert; Zammad's server-side fetch
  # verifies SSL by default and fails with 'certificate verify failed'. Disable
  # verification ONLY when explicitly pointing at localhost (never in prod).
  new_option['verify_ssl'] = intake_url.include?('localhost') ? false : nil

  # assign + save without validations (data_type unchanged; only data_option moves).
  attr.data_option = new_option
  attr.save!(validate: false)
  puts "#{name}: search_url -> #{new_option['search_url']}"
end

# Clear cached attribute defs so the new search_url takes effect immediately.
Rails.cache.clear
puts 'done (cache cleared)'

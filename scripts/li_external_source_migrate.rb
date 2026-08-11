# Controlled, backup-gated conversion of the three li_* ticket fields from
# free-text `input` (varchar) to `autocompletion_ajax_external_data_source`
# (jsonb {value,label}), fed live by the intake app's /api/v1/zammad/lookup.
#
# WHY a runner and not the API/configure script:
#   ObjectManager::Attribute's `data_type_must_not_change` validator only
#   permits input<->select/tree_select/etc. — NOT autocompletion_ajax_external_data_source.
#   And the naive string->jsonb change_column has no USING clause, so it fails
#   on existing data. So we drive the change directly here: set the attribute
#   definition (skipping only that one validator), backfill the column to the
#   correct jsonb shape, then fire the standard migration (which by then is a
#   no-op column-wise and just flips the flags + rebuilds the ticket model).
#
# USAGE (from the worktree, with rbenv Ruby + bundle, dev DATABASE_URL):
#   INTAKE_LOOKUP_URL=https://localhost:3002/api/v1/zammad/lookup \
#   INTAKE_LOOKUP_TOKEN=sk-... \
#   bundle exec rails runner scripts/li_external_source_migrate.rb
#
# Env vars:
#   INTAKE_LOOKUP_URL    base of the intake lookup endpoint (per env)
#   INTAKE_LOOKUP_TOKEN  intake API key (bearer) Zammad uses to call it
#   DRY_RUN=1            print what would change, touch nothing

intake_url   = ENV.fetch('INTAKE_LOOKUP_URL')  { abort 'INTAKE_LOOKUP_URL required' }.sub(%r{/+$}, '')
intake_token = ENV.fetch('INTAKE_LOOKUP_TOKEN') { abort 'INTAKE_LOOKUP_TOKEN required' }
dry_run      = ENV['DRY_RUN'] == '1'

FIELDS = {
  'li_legal_entity'  => { type: 'legal_entity',  extra: '' },
  'li_business_unit' => { type: 'business_unit', extra: '' },
  # Product cascades off the ticket's current Business Unit via server-side
  # render_context templating (#{ticket.li_business_unit}).
  'li_product'       => { type: 'product',       extra: '&business_unit=#{ticket.li_business_unit}' },
}.freeze

def build_data_option(intake_url, intake_token, type, extra)
  {
    'null'                    => true,
    'search_url'              => "#{intake_url}?type=#{type}&query=#{'#{search.term}'}&limit=40#{extra}",
    'search_result_list_key'  => 'result',
    'search_result_value_key' => 'value',
    'search_result_label_key' => 'label',
    'bearer_token_auth'       => intake_token,
    'linktemplate'            => '',
  }
end

puts "=== li_* external-source migration (#{dry_run ? 'DRY RUN' : 'LIVE'}) ==="
puts "intake lookup: #{intake_url}"

FIELDS.each do |name, cfg|
  attr = ObjectManager::Attribute.find_by(name: name, object_lookup_id: ObjectLookup.by_name('Ticket'))
  abort "attribute #{name} not found" unless attr
  puts "\n--- #{name}: #{attr.data_type} -> autocompletion_ajax_external_data_source ---"

  new_option = build_data_option(intake_url, intake_token, cfg[:type], cfg[:extra])
  if dry_run
    puts "  would set data_type=autocompletion_ajax_external_data_source"
    puts "  search_url=#{new_option['search_url']}"
    next
  end

  # Bypass ONLY the type-change validator; run every other validation.
  attr.data_type = 'autocompletion_ajax_external_data_source'
  attr.data_option = new_option
  attr.save!(validate: false)

  # Backfill the column to the jsonb {value,label} shape BEFORE the standard
  # migration fires, preserving legacy/off-list strings verbatim.
  ActiveRecord::Base.connection.execute(<<~SQL)
    ALTER TABLE tickets ALTER COLUMN #{name} TYPE jsonb
      USING CASE
        WHEN #{name} IS NULL OR btrim(#{name}) = '' THEN '{}'::jsonb
        ELSE jsonb_build_object('value', #{name}, 'label', #{name})
      END;
  SQL
  puts "  backfilled tickets.#{name} to jsonb"
end

if dry_run
  puts "\nDRY RUN — no changes made."
  return
end

puts "\n=== firing ObjectManager::Attribute.migration_execute ==="
ObjectManager::Attribute.migration_execute(false)
puts "=== done ==="

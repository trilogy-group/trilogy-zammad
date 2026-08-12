# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

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

intake_url   = ENV.fetch('INTAKE_LOOKUP_URL') { abort 'INTAKE_LOOKUP_URL required' }.sub(%r{/+$}, '')
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
    'search_url'              => "#{intake_url}?type=#{type}&query=\#{search.term}&limit=40#{extra}",
    'search_result_list_key'  => 'result',
    'search_result_value_key' => 'value',
    'search_result_label_key' => 'label',
    'bearer_token_auth'       => intake_token,
    'linktemplate'            => '',
  }
end

puts "=== li_* external-source migration (#{dry_run ? 'DRY RUN' : 'LIVE'}) ==="
puts "intake lookup: #{intake_url}"

# ---------------------------------------------------------------------------
# Lock safety.
#
# The column rewrite needs ACCESS EXCLUSIVE on `tickets`. On a LIVE Zammad the
# table is read constantly (the scheduler alone polls
# `SELECT MAX(tickets.updated_at)` every 1-3s, plus delayed_jobs churn), so the
# ALTER usually cannot grab that lock immediately.
#
# What went wrong on prod (2026-08): with the server default `lock_timeout=0`
# the ALTER waited FOREVER for the lock and was eventually killed by
# `statement_timeout=2min` (PG::QueryCanceled). Worse, while an ALTER waits for
# ACCESS EXCLUSIVE it QUEUES every subsequent query on that table behind it —
# so a long wait degrades the whole help desk. Table size was never the issue
# (1086 rows / ~3.6 MB rewrites in milliseconds).
#
# So: take the lock with a SHORT, BOUNDED wait and retry, instead of blocking.
# Each attempt either grabs the lock and finishes fast, or gives up in a couple
# of seconds and releases the queue before anyone notices.
LOCK_TIMEOUT   = ENV.fetch('LI_LOCK_TIMEOUT', '3s')
LOCK_ATTEMPTS  = ENV.fetch('LI_LOCK_ATTEMPTS', '25').to_i
LOCK_BACKOFF_S = ENV.fetch('LI_LOCK_BACKOFF', '4').to_f

def column_type(name)
  ActiveRecord::Base.connection.select_value(
    'select data_type from information_schema.columns ' \
    "where table_name = 'tickets' and column_name = #{ActiveRecord::Base.connection.quote(name)}"
  )
end

# Rewrite one column varchar -> jsonb, preserving legacy/off-list strings verbatim.
# Idempotent: a column already jsonb is skipped, so a partial run is resumable.
def convert_column!(name)
  if column_type(name) == 'jsonb'
    puts '  column already jsonb — skipping (resumable)'
    return true
  end

  LOCK_ATTEMPTS.times do |i|
    begin
      ActiveRecord::Base.transaction do
        # Bounded lock wait: fail fast rather than queue the whole table.
        ActiveRecord::Base.connection.execute("SET LOCAL lock_timeout = '#{LOCK_TIMEOUT}'")
        # The rewrite itself is fast; make sure a slow plan can't be killed midway.
        ActiveRecord::Base.connection.execute('SET LOCAL statement_timeout = 0')
        ActiveRecord::Base.connection.execute(<<~SQL.squish)
          ALTER TABLE tickets ALTER COLUMN #{name} TYPE jsonb
            USING CASE
              WHEN #{name} IS NULL OR btrim(#{name}) = '' THEN '{}'::jsonb
              ELSE jsonb_build_object('value', #{name}, 'label', #{name})
            END
        SQL
      end
      puts "  ✓ #{name} -> jsonb (attempt #{i + 1})"
      return true
    rescue ActiveRecord::LockWaitTimeout, ActiveRecord::StatementTimeout, ActiveRecord::QueryCanceled => e
      puts "  … lock busy (attempt #{i + 1}/#{LOCK_ATTEMPTS}): #{e.class}"
      sleep LOCK_BACKOFF_S
    end
  end

  false
end

def migrate_field!(name, cfg, intake_url, intake_token, dry_run)
  attr = ObjectManager::Attribute.find_by(name: name, object_lookup_id: ObjectLookup.by_name('Ticket'))
  abort "attribute #{name} not found" if !attr
  puts "\n--- #{name}: #{attr.data_type} -> autocompletion_ajax_external_data_source ---"

  new_option = build_data_option(intake_url, intake_token, cfg[:type], cfg[:extra])
  if dry_run
    puts '  would set data_type=autocompletion_ajax_external_data_source'
    puts "  search_url=#{new_option['search_url']}"
    puts "  current column type=#{column_type(name)}"
    return
  end

  # ⚠️ ORDER MATTERS: convert the COLUMN FIRST, then save the attribute definition.
  #
  # The original order (definition first, then ALTER) left prod in a broken state
  # when the ALTER failed: li_legal_entity was declared an external-source dropdown
  # while its column was still varchar, so the widget got plain strings and the
  # field rendered BLANK for every agent. Doing the column first means a failure
  # leaves the field as plain free text — exactly as it was — and the definition
  # only ever advertises a shape the column can actually store.
  if !convert_column!(name)
    abort <<~MSG
      ✗ #{name}: could not acquire ACCESS EXCLUSIVE on tickets after #{LOCK_ATTEMPTS} attempts.
        NOTHING was changed for this field (definition untouched, column still #{column_type(name)}),
        so the environment is consistent and safe to leave as-is.
        Retry in a quieter window, or briefly stop the scheduler container to remove
        the `SELECT MAX(tickets.updated_at)` polling that competes for the lock:
          docker stop <proj>-zammad-scheduler-1
          <re-run this script>
          docker start <proj>-zammad-scheduler-1
    MSG
  end

  # Bypass ONLY the type-change validator; run every other validation.
  attr.data_type = 'autocompletion_ajax_external_data_source'
  attr.data_option = new_option
  attr.save!(validate: false)
  puts '  ✓ definition saved (data_type + search_url)'
end

FIELDS.each do |name, cfg|
  migrate_field!(name, cfg, intake_url, intake_token, dry_run)
end

if dry_run
  puts "\nDRY RUN — no changes made."
  return
end

puts "\n=== firing ObjectManager::Attribute.migration_execute ==="
ObjectManager::Attribute.migration_execute(false)

# ⚠️ MANDATORY: bust the per-record ASSET cache.
#
# Zammad caches each record's asset payload under "Ticket::aws::<id>" and only
# treats it as stale when cache['updated_at'] != record.updated_at
# (app/models/application_model/can_associations.rb#attributes_with_association_ids).
# The ALTER/backfill above rewrites the column with raw SQL, which does NOT bump
# updated_at — so every payload cached while the column was still varchar stays
# "valid" forever and keeps serving the OLD *stringified* value
# ('{"value":..,"label":..}' as a JSON STRING instead of an object).
#
# Symptom when skipped (hit on staging 2026-08): the sidebar dropdowns render
# BLANK for every untouched ticket and saving fails, while the DB, the model,
# and the search endpoint all look perfectly correct — because only the cached
# asset payload the browser consumes is wrong.
puts "\n=== busting cached asset payloads (Ticket::aws::*) ==="
Rails.cache.clear
puts '  Rails.cache cleared'

# Verify the rebuilt payload is a Hash, not a String, on a real populated ticket.
sample = Ticket.where.not(li_legal_entity: nil)
               .where("li_legal_entity::text <> '{}'")
               .reorder(:id).first
if sample
  got = sample.attributes_with_association_ids['li_legal_entity']
  if got.is_a?(Hash)
    puts "  ✓ verified ticket #{sample.id} asset payload is an object: #{got.inspect}"
  else
    warn "  ✗ ticket #{sample.id} asset payload is #{got.class} (expected Hash) — value=#{got.inspect}"
    warn '    Stale app processes are re-caching the pre-migration shape.'
    warn '    Restart ALL zammad app containers (railsserver, websocket, SCHEDULER),'
    warn '    THEN flush memcached — in that order — and re-run this check.'
  end
else
  puts '  (no populated ticket to verify against)'
end

puts <<~POST

  === done ===

  ⚠️ FINAL STEP — do NOT skip on a deployed environment:
    Any app process started BEFORE this migration still holds the old column type
    and will re-populate the shared cache with the stringified shape. Restart every
    zammad app container and THEN flush memcached (order matters):

      docker restart <proj>-zammad-scheduler-1 <proj>-zammad-railsserver-1 <proj>-zammad-websocket-1
      docker exec <proj>-zammad-memcached-1 sh -lc 'echo flush_all | nc -w1 127.0.0.1 11211'

    Then confirm the API serves objects (not strings):
      curl -s "$ZAMMAD_URL/api/v1/tickets/<id>?all=true" -H "Authorization: Token token=$ZAMMAD_TOKEN" \\
        | python3 -c "import sys,json; a=json.load(sys.stdin)['assets']['Ticket']; \\
                      v=list(a.values())[0]['li_legal_entity']; print(type(v).__name__, v)"
      # expect: dict {...}   NOT: str '{"value":...}'
POST

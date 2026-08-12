#!/usr/bin/env bash
# Mirror PROD-SHAPED business-context reference data + realistic ticket values into the
# LOCAL environment, so local reproduces the data conditions that exist in staging/prod.
#
# WHY THIS EXISTS
#   The li_* external-source dropdown work shipped to staging and broke, because local
#   could not reproduce the real conditions:
#     * local had ~149 synthetic entities / 17 BUs / 17 products; prod has 339 entities
#       (78 of them INACTIVE), 76 BUs, 253 products.
#     * local had no CASE-VARIANT pairs (prod has e.g. "2hr Learning AL, Inc." AND
#       "2HR Learning AL, Inc.", one active + one not) and no legacy off-list values.
#     * local tickets carried tidy values, so the varchar->jsonb migration + the
#       stale-asset-cache failure mode never surfaced until real data hit it.
#
# WHAT IT SEEDS
#   1. intake DB (local Supabase): legal_entities / business_units / products with
#      prod-like NAMES, prod-like active/inactive mix, and the case-variant pairs.
#   2. local Zammad tickets: spreads those values across existing tickets, deliberately
#      including the nasty cases -> blank/NULL, an inactive ("legitimately deactivated")
#      entity, a case-variant, and an off-list legacy string.
#
# USAGE
#   bash dev/seed-prod-like-business-context.sh            # seed everything
#   bash dev/seed-prod-like-business-context.sh --refs     # reference data only
#   bash dev/seed-prod-like-business-context.sh --tickets  # ticket values only
#
# REQUIREMENTS
#   * local Supabase running (supabase_db_legal-intake container)
#   * local Zammad postgres running (legal-intake-zammad-zammad-postgres-1)
#   * data file: dev/prod-business-context-sample.json (committed alongside this script)
set -euo pipefail

INTAKE_DB_CONTAINER="${INTAKE_DB_CONTAINER:-supabase_db_legal-intake}"
ZAMMAD_DB_CONTAINER="${ZAMMAD_DB_CONTAINER:-legal-intake-zammad-zammad-postgres-1}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_FILE="${HERE}/prod-business-context-sample.json"

DO_REFS=1
DO_TICKETS=1
case "${1:-}" in
  --refs) DO_TICKETS=0 ;;
  --tickets) DO_REFS=0 ;;
  "") ;;
  *) echo "unknown arg: $1" >&2; exit 2 ;;
esac

[[ -f "$DATA_FILE" ]] || { echo "missing data file: $DATA_FILE" >&2; exit 1; }

intake_psql() { docker exec -i "$INTAKE_DB_CONTAINER" psql -U postgres -d postgres -v ON_ERROR_STOP=1 "$@"; }
zammad_psql() { docker exec -i "$ZAMMAD_DB_CONTAINER" psql -U postgres -d zammad -v ON_ERROR_STOP=1 "$@"; }

echo "==> checking containers"
docker inspect "$INTAKE_DB_CONTAINER" >/dev/null 2>&1 || { echo "intake DB container not running: $INTAKE_DB_CONTAINER" >&2; exit 1; }
docker inspect "$ZAMMAD_DB_CONTAINER" >/dev/null 2>&1 || { echo "zammad DB container not running: $ZAMMAD_DB_CONTAINER" >&2; exit 1; }

if [[ "$DO_REFS" == "1" ]]; then
  echo "==> seeding intake reference data (idempotent upsert by name)"
  # Build the SQL from the JSON sample with python (keeps quoting sane).
  python3 - "$DATA_FILE" <<'PY' > /tmp/li_seed_refs.sql
import json, sys
doc = json.load(open(sys.argv[1]))
def q(s): return "'" + str(s).replace("'", "''") + "'"
out = ["begin;"]
# Entities: upsert by name, preserving the active/inactive mix.
for e in doc["entities"]:
    out.append(
        "insert into legal_entities (id, name, is_active, created_at, updated_at) "
        f"values (gen_random_uuid(), {q(e['name'])}, {str(e['is_active']).lower()}, now(), now()) "
        "on conflict (name) do update set is_active = excluded.is_active, updated_at = now();"
    )
# Business units: upsert by name.
for b in doc["business_units"]:
    out.append(
        "insert into business_units (id, name, is_active, created_at, updated_at) "
        f"values (gen_random_uuid(), {q(b['name'])}, {str(b['is_active']).lower()}, now(), now()) "
        "on conflict (name) do update set is_active = excluded.is_active, updated_at = now();"
    )
# Products: need the BU FK; resolve by BU name.
# NOTE: products has NO unique constraint on name (only legal_entities/business_units do),
# so ON CONFLICT is not available here — upsert manually on (name, business_unit_id).
for p in doc["products"]:
    out.append(
        "with bu as (select id from business_units where name = " + q(p['business_unit']) + "), "
        "upd as ("
        "  update products p set is_active = " + str(p['is_active']).lower() + ", updated_at = now() "
        "  from bu where p.business_unit_id = bu.id and p.name = " + q(p['name']) + " returning p.id"
        ") "
        "insert into products (id, name, business_unit_id, is_active, created_at, updated_at) "
        "select gen_random_uuid(), " + q(p['name']) + ", bu.id, " + str(p['is_active']).lower() + ", now(), now() "
        "from bu where not exists (select 1 from upd);"
    )
out.append("commit;")
print("\n".join(out))
PY
  intake_psql -q -f /dev/stdin < /tmp/li_seed_refs.sql
  echo "    counts now:"
  intake_psql -t -A -F' | ' -c "
    select 'legal_entities', count(*) filter (where is_active) || ' active / ' || count(*) || ' total' from legal_entities
    union all select 'business_units', count(*) filter (where is_active) || ' active / ' || count(*) || ' total' from business_units
    union all select 'products', count(*) filter (where is_active) || ' active / ' || count(*) || ' total' from products;"
fi

if [[ "$DO_TICKETS" == "1" ]]; then
  echo "==> spreading realistic values across local Zammad tickets"
  # Detect whether the li_* columns are still varchar (pre-migration) or jsonb (post).
  COLTYPE="$(zammad_psql -t -A -c "select data_type from information_schema.columns where table_name='tickets' and column_name='li_legal_entity';" | tr -d '[:space:]')"
  echo "    li_legal_entity column type: ${COLTYPE:-unknown}"

  if [[ "$COLTYPE" == "jsonb" ]]; then
    WRAP_OPEN="jsonb_build_object('value',"; WRAP_MID=",'label',"; WRAP_CLOSE=")"; EMPTY="'{}'::jsonb"
  else
    WRAP_OPEN=""; WRAP_MID=""; WRAP_CLOSE=""; EMPTY="''"
  fi

  # Deliberately include the awkward cases so local mirrors reality:
  #   - a normal active value
  #   - an INACTIVE entity (valid when chosen, later deactivated by CIMS)
  #   - a CASE VARIANT of an active name
  #   - an OFF-LIST legacy string that is in no reference table
  #   - blank/empty (the ~33% of prod tickets with no entity)
  zammad_psql <<SQL
begin;
with ranked as (
  select id, row_number() over (order by id) as rn, count(*) over () as total from tickets
)
update tickets t set
  li_legal_entity = case (r.rn % 5)
    when 0 then ${EMPTY}
    when 1 then ${WRAP_OPEN}'Alpha School, LLC'${WRAP_MID}'Alpha School, LLC'${WRAP_CLOSE}
    when 2 then ${WRAP_OPEN}'Avolin, LLC'${WRAP_MID}'Avolin, LLC'${WRAP_CLOSE}
    when 3 then ${WRAP_OPEN}'2HR Learning AL, Inc.'${WRAP_MID}'2HR Learning AL, Inc.'${WRAP_CLOSE}
    else        ${WRAP_OPEN}'LEGACY - Not In CIMS List'${WRAP_MID}'LEGACY - Not In CIMS List'${WRAP_CLOSE}
  end,
  li_business_unit = case (r.rn % 4)
    when 0 then ${EMPTY}
    when 1 then ${WRAP_OPEN}'Crossover'${WRAP_MID}'Crossover'${WRAP_CLOSE}
    when 2 then ${WRAP_OPEN}'2HR Learning'${WRAP_MID}'2HR Learning'${WRAP_CLOSE}
    else        ${WRAP_OPEN}'Contently'${WRAP_MID}'Contently'${WRAP_CLOSE}
  end,
  li_product = case (r.rn % 4)
    when 0 then ${EMPTY}
    when 1 then ${WRAP_OPEN}'XO 3rd Party'${WRAP_MID}'XO 3rd Party'${WRAP_CLOSE}
    when 2 then ${WRAP_OPEN}'Edu Media'${WRAP_MID}'Edu Media'${WRAP_CLOSE}
    else        ${WRAP_OPEN}'Contently Product'${WRAP_MID}'Contently Product'${WRAP_CLOSE}
  end
from ranked r where r.id = t.id;
commit;
SQL

  echo "    distribution now:"
  zammad_psql -t -A -F' | ' -c "
    select coalesce(li_legal_entity::text,'(null)'), count(*) from tickets group by 1 order by 2 desc limit 8;"

  cat <<'NOTE'

    ⚠️ If you just seeded PRE-migration (varchar) values in order to rehearse the
       migration, remember the failure mode this whole script exists to catch:
       after running scripts/li_external_source_migrate.rb you MUST restart every
       Zammad app process and THEN flush memcached, or cached asset payloads keep
       serving the old *stringified* value and every sidebar dropdown renders blank.
NOTE
fi

echo "==> done"

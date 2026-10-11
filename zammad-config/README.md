# Zammad Configuration

JSON configuration files for all environments. Applied via TypeScript scripts in `trilogy-zammad/scripts/`, invoked through `pnpm` scripts defined in `trilogy-zammad/package.json`.

## Structure

```
zammad-config/
├── local/     ← local dev config (localhost overrides, http, password login enabled)
├── staging/   ← staging config (staging FQDN, staging webhook URL)
└── prod/      ← production config (source of truth)
```

Each environment directory also contains a gitignored `.env` with API credentials (copy from `.env.example`).

## Applying config

```bash
# From trilogy-zammad/

# Apply a single config type to local
pnpm run zammad:local:configure-settings
pnpm run zammad:local:configure-triggers
pnpm run zammad:local:configure-roles
pnpm run zammad:local:configure-groups
pnpm run zammad:local:configure-overviews
pnpm run zammad:local:configure-object-attributes
pnpm run zammad:local:configure-core-workflows
pnpm run zammad:local:configure-ticket-states
pnpm run zammad:local:configure-text-modules
pnpm run zammad:local:configure-schedulers

# Apply all config to local
pnpm run zammad:local:configure-all

# Apply all config to staging
pnpm run zammad:staging:configure-all

# Apply all config to prod
pnpm run zammad:prod:configure-all
```

Scripts are **idempotent** — re-running reports `unchanged` for anything already in the desired state, and only pushes real diffs.

## ⚠️ Object-attribute changes require a migration step

Zammad does **not** apply object-attribute changes (adding/removing custom fields, changing `position`, or editing the `screens` visibility config) to the live database immediately. The `configure-object-attributes` script writes the change into Zammad's "pending" object-manager state, but the field will **not appear or reorder in the ticket UI** until you run the object-manager **migration**.

The `configure-object-attributes` script prints a reminder when it finishes, but does **not** run the migration for you.

### Apply order (when a change touches object attributes)

Run these in order — object-attributes **first**, then the migration, then the rest:

```bash
# 1. Push the attribute definitions (positions, screens, new fields)
pnpm run zammad:<env>:configure-object-attributes

# 2. Execute the object-manager migration so the changes go live.
#    Either click Admin → Objects → "Execute Migrations" in the Zammad UI,
#    OR fire the API endpoint directly (uses the same ZAMMAD_URL / ZAMMAD_TOKEN):
curl -s -X POST \
  -H "Authorization: Token token=$ZAMMAD_TOKEN" \
  "$ZAMMAD_URL/api/v1/object_manager_attributes_execute_migrations"

# 3. Now apply the rest (these take effect immediately — no migration needed)
pnpm run zammad:<env>:configure-field-visibility
pnpm run zammad:<env>:configure-core-workflows
pnpm run zammad:<env>:configure-triggers
```

**Why order matters:** `configure-object-attributes` PUTs the *entire* attribute — including its `screens` block — so if you run `configure-field-visibility` **first** and `configure-object-attributes` **second**, the object-attributes push can overwrite the visibility change (the two files must stay in sync on the `screens` sub-keys). Keep `zammad-object-attributes.json` and `zammad-field-visibility.json` consistent, apply object-attributes first, then run the migration, then field-visibility.

`configure-field-visibility`, `configure-core-workflows`, and `configure-triggers` apply to the live DB immediately and do **not** need a migration.


## Making a config change

1. Edit the JSON file in the appropriate `zammad-config/{env}/` directory
2. Apply it:

```bash
# Example: tweak a setting on local
vim zammad-config/local/zammad-settings.json
pnpm run zammad:local:configure-settings

# Example: add a trigger to staging
vim zammad-config/staging/zammad-triggers.json
pnpm run zammad:staging:configure-triggers
```

## Exporting from a live instance

Captures the current state of a live Zammad into local JSON files:

```bash
pnpm run zammad:staging:export-all
pnpm run zammad:prod:export-all
```

## Environment differences

| File | local | staging | prod |
|------|-------|---------|------|
| `zammad-settings.json` | `fqdn: localhost`, `http_type: http`, password login on | staging FQDN, https | prod FQDN, https |
| `zammad-triggers.json` | webhook → `host.docker.internal:3000` | staging webhook URL | prod webhook URL |
| `zammad-webhooks.json` | created by `setup.sh`, not checked in | staging webhook | prod webhook |

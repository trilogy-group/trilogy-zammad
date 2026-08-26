# Onboarding for AI Agents

Purpose: Give an AI coding agent a fast, reliable mental model of this repo to ship changes with minimal trial-and-error.

## ⚠️ Trilogy fork — CI/CD, branches & deploy (read FIRST)

This is a **fork of `zammad/zammad`** customized for the Legal Intake platform. The
generic Zammad onboarding below still applies to app code, but our ship model is
Trilogy-specific:

- **Branches:** `main` = **production**, `staging` = staging. Both are persistent and
  protected (rulesets "Protect main" strict / "Protect staging" non-strict; PR required;
  required checks: `Dockerfile check`, `Zammad config validate`, `Semgrep`;
  repo-admin is a bypass actor). **Merge methods differ per branch (deliberate): `staging`
  is squash-only (collapse feature noise into one commit); `main` is merge-commit-only
  (promotions preserve staging's ancestry so the two long-lived branches never diverge —
  never squash a `staging`→`main` promotion).** Upstream Zammad is tracked via the `upstream`
  remote only — never let it flow into `main` automatically. `develop`/`stable-*` are upstream's branches; ignore.
- **Auto-deploy on merge** (`.github/workflows/deploy.yaml`): push to `staging` → build
  `staging-<sha>-arm64` → deploy to the `zammad-staging` EC2 box; push to `main` →
  `main-<sha>-arm64` + `:latest` → deploy to `zammad-prod`. Mechanism = GitHub Actions →
  **AWS SSM RunCommand** (`docker compose pull && up -d`) on the box, resolved by `Name` tag.
  DB migrations ride along automatically via the `zammad-init` container. Health-checked;
  per-env concurrency. (The old build-only `ecr-release.yaml` is gone.)
- **Feature work:** branch off `staging` → PR into `staging` (squash) → promote `staging`→`main`
  via a PR titled `[Promote to Main]: <scope>` listing each included PR.
- **Runtime config as code** (`zammad-config/{local,staging,prod}/*.json` + `scripts/`): triggers,
  roles, settings, object-attributes etc. are live DB rows (NOT baked into the image). **A merge that
  changes `zammad-config/<env>/*.json` AUTO-APPLIES it to that env's live Zammad** after deploy, via
  `scripts/ci-apply-all-config.sh` (full ordered, NON-destructive — never sets `DELETE_UNLISTED_*`;
  object-attributes + object-manager migration first). A config-only merge SKIPS the image build.
  Manual apply still works for one-offs: `pnpm run zammad:<env>:configure-*`. `export-*` dumps.
- **Gotchas:**
  - `gh` has an `upstream` remote → bare `gh run/api` resolve to `zammad/zammad` and 404. Always pass
    `--repo trilogy-group/trilogy-zammad`.
  - Keep repo setting **`delete_branch_on_merge = false`** — when it was `true`, merging a
    `staging`→`main` PR auto-deleted the persistent `staging` branch. Recreate if lost:
    `git branch -f staging origin/main && git push origin staging`.
  - Deploy runs the remote script under **`/bin/sh` (dash)** — no `set -o pipefail`.
  - Actions are SHA-pinned with a `# vN` comment (Semgrep `github-actions-mutable-action-tag` requires it).
  - Infra (EC2 boxes, ECR, SSM params, the version-param bootstrap) lives in the **`legal-intake-iac`**
    repo — see its `AGENTS.md`.
- **AWS auth:** account `791359514580`, profile `legalintake`, via `saml2aws login --profile=legalintake`
  (KeyCloak SAML, ~1h sessions), NOT AWS SSO.

### The platform: three repos
This help desk is one of three sibling repos (clone side-by-side under one parent dir):
| Repo | Role |
|---|---|
| **legal-intake** | Next.js intake app (raises tickets here via REST + receives our webhooks). See its `AGENTS.md`. |
| **trilogy-zammad** (this) | Customized Zammad help desk — attorney ticketing + contract-review workflow. |
| **legal-intake-iac** | AWS CDK for THIS repo's EC2 boxes, ECR, SSM params, the version-param bootstrap. See its `AGENTS.md`. |

### Local development
Full setup — running Zammad natively wired to a local legal-intake — is in **`dev/README.md`**
(don't duplicate it). Essentials:
- Clone `legal-intake` + `legal-intake-zammad` as **siblings**; `dev/setup.sh` finds the app at
  `../../legal-intake` (or set `LEGAL_INTAKE_DIR`).
- Deps: Docker, rbenv + Ruby 3.4.9, forego, Node 22+, pnpm 10+, libpq.
- `pnpm run zammad:local:up` (Postgres/ES/Redis/Memcached in Docker) → `pnpm run zammad:local:setup`
  → `pnpm run zammad:local:dev` (Rails+Vite native via `bin/dev`). Zammad on **http://localhost:3001**,
  legal-intake on **https://localhost:3000** (not interchangeable — webhook + API wiring depends on them).
- Local Zammad DB: `docker exec legal-intake-zammad-zammad-postgres-1 psql -U postgres -d zammad`
  (DB name is `zammad`, NOT `zammad_production`; role `zammad` doesn't exist — use `postgres`).
- After a role/core-workflow/object-attribute change, flush caches
  (`echo flush_all | nc -w1 localhost 11211` + `redis-cli FLUSHDB`) then re-login — Core Workflow
  eval is bound to the session's cached role_ids.
- Apply config locally with `pnpm run zammad:local:configure-*` (see `zammad-config/README.md`).
- **Hot-reload:** `zammad:local:dev` runs `bin/dev` natively from the current dir. Vue/TS frontend →
  Vite HMR (instant); Rails request code (controllers/models/services) → reloads on next request;
  **background-job/worker code (triggers, notifications, schedulers, `app/jobs`) + `config/*` +
  Gemfile do NOT hot-reload → restart `bin/dev`.**
- **Running from a git worktree:** works (`bin/dev` runs that worktree's branch code) — but a fresh
  worktree lacks the gitignored deps/env, so first `cp ../../legal-intake-zammad/.env .`, then
  `pnpm install` + `bundle install`. Infra containers + the local DB are **shared** (run
  `zammad:local:up` once; don't double-start), and only **one `bin/dev` at a time** (ports collide).
  Full detail in `dev/README.md` → "Running from a git worktree".

## Summary

- Zammad is an open-source helpdesk/customer support platform.
  It’s a Ruby on Rails app with two modern Vue 3 frontends (desktop-view and mobile)
  and one legacy desktop-app under app/assets.
- For authoritative setup, runtime, and environment details, always refer to:
  - [`../doc/developer_manual/`](../doc/developer_manual/) (index: [`../doc/developer_manual/index.md`](../doc/developer_manual/index.md))
  - [`../package.json`](../package.json), [`../Gemfile`](../Gemfile), [`../config/database.yml`](../config/database.yml),
    [`../Procfile.dev`](../Procfile.dev), [`../vite.config.mjs`](../vite.config.mjs), [`../tsconfig.base.json`](../tsconfig.base.json),
    [`../.oxlintrc.json`](../eslint.config.ts), and other config files in the repo.
- Apps:
  - desktop-app (legacy, [`../app/assets`](../app/assets)): legacy UI using REST API + CoffeeScript/Sprockets.
    Uses the Spine.js MVC framework for frontend structure and state management.
  - desktop-view ([`../app/frontend/apps/desktop`](../app/frontend/apps/desktop)): new UI using Vue + GraphQL.
  - mobile ([`../app/frontend/apps/mobile`](../app/frontend/apps/mobile)): new UI using Vue + GraphQL.

## Tech stack (see configs for details)

- Legacy desktop-app: CoffeeScript, Spine.js, Sprockets, REST API
  (see [`../app/assets/`](../app/assets/), [`../coffeelint.json`](../coffeelint.json), QUnit in `../test/`)
- New desktop-view and mobile apps: Vue 3, TypeScript, Pinia, Apollo Client (GraphQL), Tailwind CSS, VueUse,
  Vitest, Testing Library, Cypress, pnpm, vite-plugin-ruby, vite-plugin-pwa, ESLint, Stylelint, Oxfmt
  (see [`../package.json`](../package.json), [`../vite.config.mjs`](../vite.config.mjs),
  [`../tsconfig.base.json`](../tsconfig.base.json), [`../eslint.config.ts`](../eslint.config.ts))
- Backend: Ruby on Rails, PostgreSQL, Redis, ActionCable, Delayed Job, GraphQL
  (see [`../Gemfile`](../Gemfile), [`../config/`](../config/))

## Project structure (high-level)

- [`../app/assets/`](../app/assets/): legacy desktop-app (CoffeeScript/Sprockets)
- [`../app/frontend/`](../app/frontend/): Vue + TS frontends
- [`../app/frontend/apps/desktop`](../app/frontend/apps/desktop),
  [`../app/frontend/apps/mobile`](../app/frontend/apps/mobile): app-specific code
- [`../app/frontend/shared/`](../app/frontend/shared/): cross-app modules (components, utils, stores, graphql, i18n)
- [`../app/frontend/tests/`](../app/frontend/tests/): vitest setup and helpers
- Rails standard: [`../app/controllers/`](../app/controllers/), [`../app/models/`](../app/models/), [`../app/views/`](../app/views/),
  [`../app/jobs/`](../app/jobs/), [`../app/mailers/`](../app/mailers/), [`../app/helpers/`](../app/helpers/), [`../app/channels/`](../app/channels/),
  [`../app/policies/`](../app/policies/)
- [`../app/services/`](../app/services/): business logic modules (not Rails standard, but common)
- [`../app/graphql/`](../app/graphql/): GraphQL API definitions and resolvers
- Other key folders: [`../bin/`](../bin/), [`../config/`](../config/), [`../db/`](../db/), [`../doc/developer_manual/`](../doc/developer_manual/),
  [`../script/`](../script/), [`../spec/`](../spec/), [`../test/`](../test/)

## lib/ directory overview

- The [`../lib/`](../lib/) directory contains core extensions, helpers, integrations, and business logic modules
  that are not part of the Rails standard structure but are essential for Zammad's backend functionality.
- It includes:
  - **Helpers and utilities:** e.g., `email_helper.rb`, `migration_helper.rb`, `sql_helper.rb`, `image_helper.rb`,
    `time_range_helper.rb`, `session_helper.rb`, `notification_factory.rb`, and more.
  - **Integrations:** Subfolders and files for external services such as `github/`, `gitlab/`, `microsoft_graph/`,
    `facebook.rb`, `telegram_helper.rb`, `whatsapp/`, and others.
  - **Business logic and features:** e.g., `auto_wizard.rb`, `bulk_import_info.rb`, `calendar_subscriptions/`,
    `escalation/`, `excel_sheet/`, `external_data_source/`, `knowledge_base/`, `password_policy/`,
    `secure_mailing/`, `stats/`, `tasks/`, etc.
  - **Core extensions:** e.g., `core_ext/` for Ruby or Rails extensions.
  - **Background services and operations:** e.g., `background_services/`, `operations_rate_limiter.rb`,
    `sequencer/`, `transaction_dispatcher.rb`.
  - **Other:** `app_version.rb`, `exceptions.rb`, `models.rb`, `version.rb`, and more.
- Many subfolders contain related modules or classes grouped by feature or integration.

## Runtime, environment, and coding standards

- All runtime and environment constraints are defined in config files. See above for references.
- For setup, troubleshooting, testing, linting, and coding standards, always consult the Developer Manual
  ([`../doc/developer_manual/`](../doc/developer_manual/)).
- For tool versions, scripts, and environment variables, see [`../package.json`](../package.json), [`../Gemfile`](../Gemfile),
  and other config files.
- For path aliases, see [`../tsconfig.base.json`](../tsconfig.base.json).
  For copyright/i18n, see [`../eslint.config.ts`](../eslint.config.ts).

## Legacy desktop-app tips

- Location: [`../app/assets/javascripts`](../app/assets/javascripts) and [`../app/assets/stylesheets`](../app/assets/stylesheets).
- Uses Spine.js for MVC structure. Most modules are Spine classes.
- Uses REST API endpoints (see Rails controllers for routes).
- Linting: [`../coffeelint.json`](../coffeelint.json). Testing: QUnit in [`../test/`](../test/).
- Prefer new work in desktop-view/mobile; keep legacy changes minimal.

## Vue apps tips

- Use path aliases from [`../tsconfig.base.json`](../tsconfig.base.json).
- Do not cross-import between desktop/mobile apps (ESLint enforces boundaries).
- Use Vitest and Testing Library for unit/component tests ([`../app/frontend/tests/`](../app/frontend/tests/)).
- Use Tailwind CSS utilities for styling. Lint with Stylelint and Oxfmt.
- For i18n, wrap user-facing strings and see [`../eslint.config.ts`](../eslint.config.ts) for rules.

## When in doubt

- The Developer Manual ([`../doc/developer_manual/`](../doc/developer_manual/)) is the source of truth for setup,
  testing, and standards.
- Prefer referencing config files over duplicating information here.
- Keep PRs focused; include tests for new code.

# Legal Intake — Zammad (Trilogy fork)

> This is **`trilogy-group/trilogy-zammad`**, a customized fork of
> [`zammad/zammad`](https://github.com/zammad/zammad) that powers the attorney help desk for the
> **Legal Intake** platform. The upstream Zammad README follows below; **this section is the
> Trilogy-specific bit you need first.** Deeper agent/contributor detail is in
> [`AGENTS.md`](./AGENTS.md); local setup is in [`dev/README.md`](./dev/README.md).

## Branching convention

| Branch | Role | Deployed to |
|---|---|---|
| `main` | **production** | `zammad-prod` → https://tickets.legal-intake.ti.trilogy.com |
| `staging` | staging | `zammad-staging` → https://staging-tickets.legal-intake.ti.trilogy.com |

- Both branches are **persistent and protected** (PR required, **squash-only**, required checks:
  `Dockerfile check`, `Zammad config validate`, `Semgrep`).
- **Upstream Zammad** is tracked via the `upstream` git remote only — it is **never** merged into
  `main` automatically. Do **not** click GitHub's "Sync fork" button (it would drop hundreds of
  upstream commits onto our production line). Pull upstream deliberately into a throwaway branch and
  cherry-pick.
- `develop` / `stable-*` are upstream Zammad's own branches — ignore them for Trilogy work.

## How to make changes

1. **Branch off `staging`:** `git checkout staging && git pull && git checkout -b feat/my-change`
2. Make your change, open a **PR into `staging`** — it's merged with **squash**. The required checks
   run automatically; a merge to `staging` **auto-deploys to the staging box**.
3. Verify on staging (https://staging-tickets.legal-intake.ti.trilogy.com).
4. **Promote to production:** open a PR from `staging` → `main`, titled
   **`[Promote to Main]: <short scope>`**, with the body listing each included PR. Squash-merge it —
   the merge **auto-deploys to production**.

**What "a change" means here — two distinct kinds:**
- **App/image code** (Ruby/Rails, Vue frontends, Dockerfile): ships in the Docker image built by
  `.github/workflows/deploy.yaml` and deployed via SSM on merge. DB migrations ride along
  automatically (the `zammad-init` container runs `rails db:migrate` on deploy).
- **Runtime config** (triggers, roles, settings, object-attributes, overviews, webhooks, …): these
  are live DB rows, **not** image code. They live as JSON under `zammad-config/{local,staging,prod}/`.
  **Merging a change to `zammad-config/<env>/*.json` auto-applies it to that env's live Zammad**
  (after deploy, via `scripts/ci-apply-all-config.sh` — full ordered, non-destructive apply). A
  config-only merge **skips the image build** and just applies the config. Manual apply is still
  available for one-offs: `pnpm run zammad:<env>:configure-*` (see
  [`zammad-config/README.md`](./zammad-config/README.md)).

## Deploy & infrastructure

- **Auto-deploy on merge** — no manual step. GitHub Actions builds the arm64 image → pushes to ECR
  → deploys to the matching EC2 box via **AWS SSM RunCommand** (`docker compose pull && up -d`) →
  health-checks. See [`AGENTS.md`](./AGENTS.md) for the full pipeline + gotchas.
- The EC2 boxes, ECR repo, and SSM parameters are provisioned by the **`legal-intake-iac`** repo
  (AWS CDK) — a separate, manually-deployed repo.
- `gh` note: this repo has an `upstream` remote, so always pass
  `--repo trilogy-group/trilogy-zammad` to `gh` commands (bare `gh` resolves to `zammad/zammad`).

---

# Welcome to Zammad

Are you juggling countless customer inquiries across multiple channels?
Struggling to keep your support team on the same page?
Or spending more time managing your helpdesk than delivering exceptional support to your customers?

Zammad is your Swiss Army knife - a web-based, open-source helpdesk and customer support platform
packed with features to streamline customer communication across channels like email, chat, telephone and social media.

## The Software

The Zammad software is and will stay open source. It is licensed under the GNU AGPLv3.
The source code is [available on GitHub](https://github.com/zammad/zammad) and owned by
the [Zammad Foundation](https://zammad-foundation.org/), which is independent of commercial
providers such as Zammad GmbH.

## The Company - Zammad GmbH

The development of Zammad is carried out by the [amazing team of people](https://zammad.com/en/company)
at [Zammad GmbH](https://zammad.com/) in collaboration with the community.
We love to create open source software for you. If you want to ensure the Zammad software
has a bright and sustainable future, consider becoming a Zammad customer!

> Are you tired of complex setup, configuration, backup and update tasks? Let us handle this stuff for you! 🚀
>
> The easiest and often most cost-effective way to operate Zammad is [our cloud service](https://zammad.com/en/pricing).
> Give it a try with a [free trial instance](https://zammad.com/en/getting-started)!

## Status

- Toolchain: [![CI](https://github.com/zammad/zammad/workflows/CI/badge.svg)](https://github.com/zammad/zammad/actions/workflows/ci.yaml)
  [![docker-release workflow](https://github.com/zammad/zammad/workflows/docker-release/badge.svg)](https://github.com/zammad/zammad/actions/workflows/docker-release.yaml)
  [![documentation status](https://readthedocs.org/projects/zammad/badge/)](https://docs.zammad.org)
- Docker container images: [![Docker images for Zammad](https://img.shields.io/badge/version-stable-blue.svg)](https://hub.docker.com/r/zammad/zammad-docker-compose)
  [![Dockerhub Pulls](https://badgen.net/docker/pulls/zammad/zammad-docker-compose?icon=docker&label=pulls)](https://hub.docker.com/r/zammad/zammad-docker-compose/)
- Helm chart for Kubernetes: [![Artifact Hub](https://img.shields.io/endpoint?url=https://artifacthub.io/badge/repository/zammad)](https://artifacthub.io/packages/helm/zammad/zammad)
  [![Release downloads](https://img.shields.io/github/downloads/zammad/zammad-helm/total.svg)](https://github.com/zammad/zammad-helm/releases)
- Download DEB/RPM: [![binary packages for Zammad stable](https://img.shields.io/badge/Branch-stable-blue.svg)](https://packager.io/gh/zammad/zammad/refs/stable)
  [![binary packages for Zammad develop](https://img.shields.io/badge/Branch-develop-lightgrey.svg)](https://packager.io/gh/zammad/zammad/refs/develop)
- License: [![AGPL license](https://img.shields.io/badge/License-AGPL%203.0-brightgreen.svg)](https://github.com/zammad/zammad/blob/develop/LICENSE)

## Further Information

- [Installing & Getting Started](https://docs.zammad.org)
- [Screenshots](https://zammad.org/screenshots)
- [Developer Manual](/doc/developer_manual/index.md)
- [REST API](https://docs.zammad.org/en/latest/api/intro.html)
- For reporting security vulnerabilities, please see [our security policy](SECURITY.md).
- [Contributing](https://zammad.org/participate)

Thanks! ❤️ ❤️ ❤️

 Your Zammad Team

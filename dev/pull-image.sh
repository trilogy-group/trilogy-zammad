#!/usr/bin/env bash
# Pull the latest legal-intake-zammad image from ECR and tag it as zammad-local-custom:latest.
#
# Prerequisites:
#   - AWS credentials configured (saml2aws login, or AWS_* env vars set)
#   - legal-intake-zammad repo cloned alongside legal-intake
#   - docker running
#
# Usage:
#   npm run zammad:local:pull-image
#   bash zammad/local/pull-image.sh

set -euo pipefail

ECR_REGISTRY="791359514580.dkr.ecr.us-east-1.amazonaws.com"
ECR_REPO="legal-intake/zammad"
ECR_BRANCH="feat/ecr-release"
LOCAL_TAG="zammad-local-custom:latest"
AWS_REGION="${AWS_REGION:-us-east-1}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ZAMMAD_FORK_DIR="$(cd "$SCRIPT_DIR/../../../.." && pwd)/legal-intake-zammad"

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
bold()   { printf '\033[1m%s\033[0m\n' "$*"; }
die()    { red "Error: $*"; exit 1; }

bold "=== Zammad image pull from ECR ==="
echo ""

# ── Resolve SHA from legal-intake-zammad ────────────────────────────────────
if [ ! -d "$ZAMMAD_FORK_DIR/.git" ]; then
  die "legal-intake-zammad repo not found at $ZAMMAD_FORK_DIR
Clone it first:
  cd $(dirname $ZAMMAD_FORK_DIR)
  git clone https://github.com/trilogy-group/trilogy-zammad.git"
fi

echo "Fetching latest commits from legal-intake-zammad..."
git -C "$ZAMMAD_FORK_DIR" fetch origin "$ECR_BRANCH" --quiet 2>/dev/null \
  || die "Could not fetch from legal-intake-zammad. Check your network / credentials."

SHORT_SHA=$(git -C "$ZAMMAD_FORK_DIR" rev-parse --short=7 "origin/$ECR_BRANCH")
BRANCH_SLUG=$(echo "$ECR_BRANCH" | sed 's/\//-/g')
ECR_TAG="${BRANCH_SLUG}-${SHORT_SHA}-arm64"
FULL_IMAGE="${ECR_REGISTRY}/${ECR_REPO}:${ECR_TAG}"

echo "  Branch : $ECR_BRANCH"
echo "  SHA    : $SHORT_SHA"
echo "  Image  : $FULL_IMAGE"
echo ""

# ── Authenticate with ECR ────────────────────────────────────────────────────
echo "Authenticating with ECR..."
ECR_PASSWORD=$(aws ecr get-login-password --region "$AWS_REGION" 2>&1) || {
  die "AWS ECR authentication failed.
Make sure your credentials are valid:
  saml2aws login
  (or set AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY / AWS_SESSION_TOKEN)"
}

echo "$ECR_PASSWORD" | docker login \
  --username AWS \
  --password-stdin \
  "$ECR_REGISTRY" > /dev/null 2>&1 \
  || die "docker login to ECR failed."

green "Authenticated with ECR."
echo ""

# ── Pull and retag ───────────────────────────────────────────────────────────
echo "Pulling $FULL_IMAGE ..."
docker pull "$FULL_IMAGE" \
  || die "Failed to pull image. It may not exist yet in ECR for this SHA.
Check: https://github.com/trilogy-group/trilogy-zammad/actions"

echo ""
echo "Tagging as $LOCAL_TAG..."
docker tag "$FULL_IMAGE" "$LOCAL_TAG"

echo ""
green "Done! $LOCAL_TAG is now up to date (SHA: $SHORT_SHA)."
echo ""
echo "Restart Zammad containers to use the new image:"
yellow "  npm run zammad:local:down && npm run zammad:local:up"

#!/usr/bin/env bash
# Checks that bootstrap fills in every generated secret on a fresh setup (`cp .env.example .env`),
# where those lines exist but are empty. Works on a temporary copy; the real .env is not touched.
set -euo pipefail
. "$(dirname "$0")/bootstrap.sh"

# Everything docker-compose.yml refuses to start without and says bootstrap makes, plus the secrets that
# only scripts need (compose leaves the admin password optional; the backup password is for offsite.sh).
GENERATED_SECRETS="$(grep -oE '\$\{[A-Z_]+:\?run scripts/bootstrap.sh\}' "$REPO_ROOT/docker-compose.yml" \
  | sed -E 's/^\$\{([A-Z_]+):.*/\1/' | sort -u | xargs) WEBUI_ADMIN_PASSWORD OFFSITE_ENCRYPTION_PASSWORD"
readonly GENERATED_SECRETS

main_check() {
  local name lines
  ENV_FILE=$(mktemp)
  on_exit_cleanup rm -f "$ENV_FILE"
  cp "$REPO_ROOT/.env.example" "$ENV_FILE"
  ensure_secrets >/dev/null
  for name in $GENERATED_SECRETS; do
    lines=$(grep -c "^$name=" "$ENV_FILE" || true)
    [ "$lines" = "1" ] || fail "$name appears $lines times in .env"
    grep -q "^$name=[0-9a-f]\{48\}$" "$ENV_FILE" || fail "$name was not generated"
  done
  pass "a fresh .env from .env.example gets every generated secret"
  # Before the first admin exists there can be no admin key; a placeholder would make bootstrap use it.
  grep -q '^OPENWEBUI_ADMIN_API_KEY=$' "$ENV_FILE" || fail ".env.example must leave OPENWEBUI_ADMIN_API_KEY empty"
  pass "a fresh .env has no admin key yet, so bootstrap skips the admin steps"
  # The Chat admin is created from .env on the first start, so bootstrap must stop until the e-mail is there.
  local message
  message=$( (require_admin_email) 2>&1 ) && fail "bootstrap goes on without WEBUI_ADMIN_EMAIL in .env"
  grep -q "add WEBUI_ADMIN_EMAIL=" <<<"$message" || fail "bootstrap does not say what to add to .env (got: $message)"
  pass "without the admin e-mail, bootstrap stops and says what to add"
  assert_failed_lookup_keeps_model_settings
}

# The admin's model names and visibility live only in Chat; bootstrap may create an entry, never reset one.
# Chat is replaced by stand-ins: the lookup answers with the given HTTP status, and any POST is recorded.
seed_with_lookup_status() (
  posts=$1 lookup_status=$2
  openwebui_admin_status() { echo "$lookup_status"; }
  openwebui_admin() { [ "$1" = GET ] && return 22; echo "$*" >> "$posts"; }
  seed_model_entry smoke-model "Smoke model" all
)

assert_failed_lookup_keeps_model_settings() {
  local posts message
  posts=$(mktemp)
  on_exit_cleanup rm -f "$posts"
  message=$(seed_with_lookup_status "$posts" 500 2>&1) && fail "bootstrap goes on when Chat cannot say whether a model entry exists"
  [ ! -s "$posts" ] || fail "a failed lookup made bootstrap reset the model entry: $(cat "$posts")"
  seed_with_lookup_status "$posts" 404 >/dev/null 2>&1 || fail "bootstrap does not create a missing model entry"
  grep -q "access/update" "$posts" || fail "bootstrap did not create the missing model entry"
  pass "when Chat does not answer, bootstrap stops instead of resetting the admin's model settings"
}

main_check "$@"

#!/usr/bin/env bash
# Checks that bootstrap fills in every generated secret on a fresh setup (`cp .env.example .env`),
# where those lines exist but are empty. Works on a temporary copy; the real .env is not touched.
set -euo pipefail
. "$(dirname "$0")/bootstrap.sh"

readonly GENERATED_SECRETS="POSTGRES_PASSWORD LITELLM_DB_PASSWORD LITELLM_UI_PASSWORD OPENWEBUI_DB_PASSWORD WEBUI_SECRET_KEY WEBUI_ADMIN_PASSWORD OFFSITE_ENCRYPTION_PASSWORD"

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
}

main_check "$@"

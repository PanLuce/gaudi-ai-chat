#!/usr/bin/env bash
# Makes the .env that CI runs with: .env.example, generated secrets, an admin e-mail and made-up
# provider keys. No check calls a provider, so the keys only have to be there (only .env values differ
# between environments). Refuses to touch an existing .env.
set -euo pipefail
. "$(dirname "$0")/bootstrap.sh"

main_ci_env() {
  [ ! -e "$ENV_FILE" ] || fail ".env already exists; scripts/ci-env.sh only makes a fresh one for CI"
  cp "$REPO_ROOT/.env.example" "$ENV_FILE"
  ensure_secrets >/dev/null
  ensure_secret LITELLM_MASTER_KEY sk- >/dev/null
  ensure_secret OPEN_TERMINAL_API_KEY >/dev/null
  set_env_value WEBUI_ADMIN_EMAIL "ci-admin@skolagaudi.cz"
  set_env_value ANTHROPIC_API_KEY "ci-not-a-real-key"
  set_env_value GEMINI_API_KEY "ci-not-a-real-key"
  pass "CI .env: generated secrets, made-up provider keys"
}

main_ci_env "$@"

#!/usr/bin/env bash
# Brings the stack to its configured state. Safe to run any number of times:
#   1. generates missing secrets into .env
#   2. starts the stack
#   3. ensures Open WebUI's own LiteLLM key (with an instance-wide monthly cap)
#   4. points Open WebUI's connection at LiteLLM with that key
set -euo pipefail
. "$(dirname "$0")/lib.sh"

# Instance-wide safety net: also caps calls that carry no user identity.
readonly OPENWEBUI_KEY_MONTHLY_BUDGET_USD=100
readonly OPENWEBUI_KEY_ALIAS="open-webui"

ensure_secret() {
  local name=$1 prefix=${2:-}
  if ! grep -q "^$name=" "$ENV_FILE"; then
    printf '%s=%s%s\n' "$name" "$prefix" "$(openssl rand -hex 24)" >> "$ENV_FILE"
    info "generated $name"
  fi
}

# Portable (GNU and BSD): rewrites .env in place, so its permissions stay as they are.
set_env_value() {
  local name=$1 value=$2 rest
  rest=$(grep -v "^$name=" "$ENV_FILE" || true)
  printf '%s\n%s=%s\n' "$rest" "$name" "$value" > "$ENV_FILE"
}

ensure_secrets() {
  ensure_secret POSTGRES_PASSWORD
  ensure_secret LITELLM_DB_PASSWORD
  ensure_secret LITELLM_UI_PASSWORD
}

openwebui_key_is_valid() {
  [ -n "${OPENWEBUI_LITELLM_KEY:-}" ] &&
    litellm_admin GET "/key/info?key=$OPENWEBUI_LITELLM_KEY" >/dev/null 2>&1
}

ensure_openwebui_litellm_key() {
  if openwebui_key_is_valid; then
    info "Open WebUI LiteLLM key is valid"
    return
  fi
  local key
  key=$(litellm_admin POST /key/generate \
    "{\"key_alias\":\"$OPENWEBUI_KEY_ALIAS\",\"max_budget\":$OPENWEBUI_KEY_MONTHLY_BUDGET_USD,\"budget_duration\":\"30d\"}" \
    | jq -er '.key') || fail "could not create the Open WebUI key in LiteLLM"
  set_env_value OPENWEBUI_LITELLM_KEY "$key"
  OPENWEBUI_LITELLM_KEY=$key
  info "created Open WebUI LiteLLM key (cap \$$OPENWEBUI_KEY_MONTHLY_BUDGET_USD / 30 days)"
}

sync_openwebui_connection() {
  if [ -z "${OPENWEBUI_ADMIN_API_KEY:-}" ]; then
    info "skipped Open WebUI connection sync: OPENWEBUI_ADMIN_API_KEY not set (see README)"
    return
  fi
  openwebui_admin POST /openai/config/update "$(jq -n --arg key "$OPENWEBUI_LITELLM_KEY" \
    '{ENABLE_OPENAI_API: true, OPENAI_API_BASE_URLS: ["http://litellm:4000/v1"], OPENAI_API_KEYS: [$key], OPENAI_API_CONFIGS: {}}')" \
    >/dev/null || fail "could not update Open WebUI's connection"
  info "Open WebUI connection points at LiteLLM with its own key"
}

main() {
  require_tools docker curl jq openssl
  load_env
  ensure_secrets
  load_env
  compose up -d --wait
  ensure_openwebui_litellm_key
  sync_openwebui_connection
  pass "bootstrap done"
}

main "$@"

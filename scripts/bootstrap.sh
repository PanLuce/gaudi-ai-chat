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

# Text models every staff member may use, in menu order: "<LiteLLM model name>|<name shown in Open WebUI>".
# The first one is the default.
readonly STAFF_TEXT_MODELS=(
  "claude-haiku|Claude Haiku (rychlý, výchozí)"
  "claude-sonnet|Claude Sonnet"
  "claude-opus|Claude Opus (nejsilnější)"
)

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
  ensure_secret OPENWEBUI_DB_PASSWORD
  ensure_secret WEBUI_SECRET_KEY
}

openwebui_key_is_valid() {
  [ -n "${OPENWEBUI_LITELLM_KEY:-}" ] &&
    litellm_as "$OPENWEBUI_LITELLM_KEY" GET /key/info >/dev/null 2>&1
}

ensure_openwebui_litellm_key() {
  if openwebui_key_is_valid; then
    info "Open WebUI LiteLLM key is valid"
    return
  fi
  local key
  # Remove keys left from earlier runs so only one key carries the instance-wide cap.
  litellm_admin POST /key/delete "{\"key_aliases\":[\"$OPENWEBUI_KEY_ALIAS\"]}" >/dev/null 2>&1 || true
  key=$(litellm_admin POST /key/generate \
    "{\"key_alias\":\"$OPENWEBUI_KEY_ALIAS\",\"max_budget\":$OPENWEBUI_KEY_MONTHLY_BUDGET_USD,\"budget_duration\":\"30d\"}" \
    | jq -er '.key') || fail "could not create the Open WebUI key in LiteLLM"
  set_env_value OPENWEBUI_LITELLM_KEY "$key"
  OPENWEBUI_LITELLM_KEY=$key
  info "created Open WebUI LiteLLM key (cap \$$OPENWEBUI_KEY_MONTHLY_BUDGET_USD / 30 days)"
}

ensure_staff_budget() {
  local budget path=/budget/new
  budget=$(jq -cn --arg id "$STAFF_BUDGET_ID" --argjson usd "$STAFF_BUDGET_USD" \
    '{budget_id: $id, max_budget: $usd, budget_duration: "30d"}')
  if litellm_admin POST /budget/info "{\"budgets\":[\"$STAFF_BUDGET_ID\"]}" 2>/dev/null | jq -e '.[0].budget_id' >/dev/null; then
    path=/budget/update
  fi
  litellm_admin POST "$path" "$budget" >/dev/null || fail "could not set staff budget '$STAFF_BUDGET_ID'"
  info "staff budget: \$$STAFF_BUDGET_USD per 30 days ($STAFF_BUDGET_ID)"
}

# Open WebUI shows a connection model only to admins until it has its own entry with access rules.
ensure_staff_model() {
  local id=$1 name=$2 form path=/api/v1/models/create
  form=$(jq -cn --arg id "$id" --arg name "$name" '{
    id: $id, base_model_id: null, name: $name, meta: {}, params: {},
    access_grants: [{principal_type: "user", principal_id: "*", permission: "read"}]}')
  if openwebui_admin GET "/api/v1/models/model?id=$id" 2>/dev/null | jq -e '.id' >/dev/null; then
    path=/api/v1/models/model/update
  fi
  openwebui_admin POST "$path" "$form" >/dev/null || fail "could not publish model $id to staff"
}

ensure_staff_models() {
  local entry ids=()
  for entry in "${STAFF_TEXT_MODELS[@]}"; do
    ensure_staff_model "${entry%%|*}" "${entry#*|}"
    ids+=("${entry%%|*}")
  done
  openwebui_admin GET /api/v1/configs/models \
    | jq -c --arg default "${ids[0]}" --args '.DEFAULT_MODELS = $default | .MODEL_ORDER_LIST = $ARGS.positional' "${ids[@]}" \
    | { read -r config; openwebui_admin POST /api/v1/configs/models "$config" >/dev/null; } \
    || fail "could not set default model"
  info "staff models: ${ids[*]} (default ${ids[0]})"
}

sync_openwebui_connection() {
  if [ -z "${OPENWEBUI_ADMIN_API_KEY:-}" ]; then
    info "skipped Open WebUI connection sync: OPENWEBUI_ADMIN_API_KEY not set (see README)"
    return
  fi
  openwebui_admin POST /openai/config/update "$(jq -n --arg key "$OPENWEBUI_LITELLM_KEY" \
    '{ENABLE_OPENAI_API: true, OPENAI_API_BASE_URLS: ["http://litellm:4000/v1"], OPENAI_API_KEYS: [$key], OPENAI_API_CONFIGS: {}}')" \
    >/dev/null || fail "could not update Open WebUI's connection: is OPENWEBUI_ADMIN_API_KEY valid? A fresh database needs a new one (README: Admin API key)"
  info "Open WebUI connection points at LiteLLM with its own key"
}

main() {
  require_tools docker curl jq openssl
  load_env
  ensure_secrets
  load_env
  compose up -d --wait
  ensure_openwebui_litellm_key
  ensure_staff_budget
  sync_openwebui_connection
  [ -n "${OPENWEBUI_ADMIN_API_KEY:-}" ] && ensure_staff_models
  pass "bootstrap done"
}

main "$@"

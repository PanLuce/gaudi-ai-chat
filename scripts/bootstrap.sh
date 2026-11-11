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

readonly IMAGE_MODEL="gemini-image"

# Initial model setup in Open WebUI: "<LiteLLM model name>|<name shown>|<who sees it: all or admin>".
# Applied only when a model has no entry yet; afterwards visibility, names and the default model
# are the admin's configuration in the UI and bootstrap leaves them alone. The first one is the default.
readonly INITIAL_MODELS=(
  "claude-haiku|Claude Haiku (rychlý, výchozí)|all"
  "claude-sonnet|Claude Sonnet|all"
  "claude-opus|Claude Opus (nejsilnější)|admin"
  "gemini-image|Gemini obrázky (pro tlačítko obrázku)|admin"
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
model_entry_exists() {
  openwebui_admin GET "/api/v1/models/model?id=$1" 2>/dev/null | jq -e '.id' >/dev/null
}

# Creates the model's entry with its initial name and visibility; existing entries are left as they are.
seed_model_entry() {
  local id=$1 name=$2 audience=$3 grants='[]'
  model_entry_exists "$id" && return 0
  [ "$audience" = "all" ] && grants='[{"principal_type": "user", "principal_id": "*", "permission": "read"}]'
  openwebui_admin POST /api/v1/models/model/access/update \
    "$(jq -cn --arg id "$id" --arg name "$name" --argjson grants "$grants" '{id: $id, name: $name, access_grants: $grants}')" \
    >/dev/null || fail "could not create model entry $id"
  info "model $id created (visible to: $audience)"
}

seed_default_model() {
  local default=$1 config
  config=$(openwebui_admin GET /api/v1/configs/models) || fail "could not read model settings"
  [ -n "$(jq -r '.DEFAULT_MODELS // empty' <<<"$config")" ] && return 0
  openwebui_admin POST /api/v1/configs/models "$(jq -c --arg d "$default" '.DEFAULT_MODELS = $d' <<<"$config")" >/dev/null \
    || fail "could not set default model"
  info "default model: $default"
}

seed_models() {
  local entry id rest name audience
  for entry in "${INITIAL_MODELS[@]}"; do
    id=${entry%%|*}; rest=${entry#*|}; name=${rest%%|*}; audience=${rest#*|}
    seed_model_entry "$id" "$name" "$audience"
  done
  seed_default_model "${INITIAL_MODELS[0]%%|*}"
}

# Image generation goes through LiteLLM too, so images count against the same budgets.
sync_openwebui_image_generation() {
  openwebui_admin GET /api/v1/images/config \
    | jq -c --arg key "$OPENWEBUI_LITELLM_KEY" --arg model "$IMAGE_MODEL" '
        .ENABLE_IMAGE_GENERATION = true | .IMAGE_GENERATION_ENGINE = "openai"
        | .IMAGES_OPENAI_API_BASE_URL = "http://litellm:4000/v1" | .IMAGES_OPENAI_API_KEY = $key
        | .IMAGE_GENERATION_MODEL = $model | .IMAGE_SIZE = "1024x1024"' \
    | { read -r config; openwebui_admin POST /api/v1/images/config/update "$config" >/dev/null; } \
    || fail "could not configure image generation"
  info "image generation: $IMAGE_MODEL through LiteLLM"
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
  if [ -n "${OPENWEBUI_ADMIN_API_KEY:-}" ]; then
    seed_models
    sync_openwebui_image_generation
  fi
  pass "bootstrap done"
}

main "$@"

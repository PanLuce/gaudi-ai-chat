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
readonly TERMINAL_ID="open-terminal"

# Initial model setup in Open WebUI: "<LiteLLM model name>|<name shown>|<who sees it: all or admin>".
# Applied only when a model has no entry yet; afterwards visibility, names and the default model
# are the admin's configuration in the UI and bootstrap leaves them alone. The first one is the default.
readonly INITIAL_MODELS=(
  "claude-haiku|Claude Haiku (rychlý, výchozí)|all"
  "claude-sonnet|Claude Sonnet|all"
  "claude-opus|Claude Opus (nejsilnější)|admin"
  "gemini-image|Gemini obrázky (pro tlačítko obrázku)|admin"
)

# A missing line and an empty value (as .env.example ships them) both get a new secret.
ensure_secret() {
  local name=$1 prefix=${2:-}
  if ! grep -q "^$name=." "$ENV_FILE"; then
    set_env_value "$name" "$prefix$(openssl rand -hex 24)"
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
  ensure_secret WEBUI_ADMIN_PASSWORD
  ensure_secret OFFSITE_ENCRYPTION_PASSWORD # without it no copy on Google Drive can be read
}

# The admin account is created from .env on Chat's first start, so the e-mail must be there before it.
require_admin_email() {
  grep -q '^WEBUI_ADMIN_EMAIL=..*@' "$ENV_FILE" \
    || fail "add WEBUI_ADMIN_EMAIL=<your school e-mail> to .env (the Chat admin account), then run bootstrap again"
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

# The HTTP status of an admin GET to Open WebUI; 000 when it does not answer at all.
openwebui_admin_status() {
  curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
    --config <(printf 'header = "Authorization: Bearer %s"\n' "$OPENWEBUI_ADMIN_API_KEY") "$OPENWEBUI_URL$1" || true
}

# Open WebUI shows a connection model only to admins until it has its own entry with access rules.
# Only "not found" means missing: a failed lookup must stop bootstrap, never reset the admin's settings.
model_entry_exists() {
  local status
  status=$(openwebui_admin_status "/api/v1/models/model?id=$1")
  case "$status" in
    200) return 0 ;;
    404) return 1 ;;
    *) fail "could not look up model entry $1 in Open WebUI (HTTP $status); nothing was changed" ;;
  esac
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

# Address and key of the terminal come from the deployment; who may use it is the connection's
# access rules. A new connection has none, which Open WebUI treats as administrators only.
sync_openwebui_terminal() {
  openwebui_admin GET /api/v1/configs/terminal_servers \
    | jq -c --arg id "$TERMINAL_ID" --arg key "$OPEN_TERMINAL_API_KEY" '
        .TERMINAL_SERVER_CONNECTIONS |= (
          (map(select(.id == $id)) | first // {config: {}}) as $current
          | map(select(.id != $id))
          + [$current + {id: $id, name: "Terminál serveru", enabled: true,
                         url: "http://open-terminal:8000", key: $key, auth_type: "bearer"}])' \
    | { read -r config; openwebui_admin POST /api/v1/configs/terminal_servers "$config" >/dev/null; } \
    || fail "could not configure the terminal connection"
  info "terminal $TERMINAL_ID connected (administrators only unless the admin grants more)"
}

# The public address is part of the deployment (.env), not an admin setting: OAuth redirects use it.
# MFA fields are left out: only a signed-in administrator may change them, not an API key,
# and Open WebUI keeps them as they are when they are not sent.
sync_openwebui_public_address() {
  openwebui_admin GET /api/v1/auths/admin/config \
    | jq -c --arg url "$OPENWEBUI_URL" '.WEBUI_URL = $url | with_entries(select(.key | test("MFA") | not))' \
    | { read -r config; openwebui_admin POST /api/v1/auths/admin/config "$config" >/dev/null; } \
    || fail "could not set Open WebUI's public address"
  info "Open WebUI public address: $OPENWEBUI_URL"
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
  require_admin_email
  load_env
  compose up -d --wait
  ensure_openwebui_litellm_key
  ensure_staff_budget
  sync_openwebui_connection
  if [ -n "${OPENWEBUI_ADMIN_API_KEY:-}" ]; then
    seed_models
    sync_openwebui_image_generation
    sync_openwebui_public_address
    sync_openwebui_terminal
  fi
  pass "bootstrap done"
}

# Sourcing (as tests do) only defines the functions.
[ "${BASH_SOURCE[0]}" != "$0" ] || main "$@"

# Shared helpers for the stack scripts. Source it, don't run it.
# Scripts read .env, which the Claude Code sandbox may not read: run them outside the sandbox.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$REPO_ROOT/.env"
LITELLM_URL="http://127.0.0.1:4000"

# Default monthly budget of every staff member; litellm/config.yaml refers to it by id.
readonly STAFF_BUDGET_ID="staff-monthly"
readonly STAFF_BUDGET_USD=5

fail() { echo "✗ $*" >&2; exit 1; }
pass() { echo "✓ $*"; }
info() { echo "• $*"; }

require_tools() {
  local tool
  for tool in "$@"; do
    command -v "$tool" >/dev/null || fail "missing tool: $tool"
  done
}

load_env() {
  [ -f "$ENV_FILE" ] || fail ".env not found at $ENV_FILE (copy .env.example)"
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
  # Scripts go the way people do: through Caddy at the public address.
  OPENWEBUI_URL="${WEBUI_URL:-http://localhost}"
}

compose() { docker compose --project-directory "$REPO_ROOT" "$@"; }

# Secrets travel through a curl config on a file descriptor, never through argv or the URL,
# so other processes on the host cannot read them with `ps`.
api_request() {
  local token=$1 method=$2 url=$3 body=${4:-}
  curl -sS --fail-with-body -X "$method" "$url" \
    --config <(printf 'header = "Authorization: Bearer %s"\n' "$token") \
    -H 'Content-Type: application/json' \
    ${body:+--data-binary @<(printf '%s' "$body")}
}

litellm_admin() {
  api_request "$LITELLM_MASTER_KEY" "$1" "$LITELLM_URL$2" "${3:-}"
}

# Calls LiteLLM as the holder of $1 itself (e.g. /key/info about that very key).
litellm_as() {
  api_request "$1" "$2" "$LITELLM_URL$3" "${4:-}"
}

openwebui_admin() {
  [ -n "${OPENWEBUI_ADMIN_API_KEY:-}" ] || fail "OPENWEBUI_ADMIN_API_KEY is not set in .env (see README: Admin API key)"
  api_request "$OPENWEBUI_ADMIN_API_KEY" "$1" "$OPENWEBUI_URL$2" "${3:-}"
}

# Cleanup registry: checks that create data register how to delete it; runs on any exit.
CLEANUP_ACTIONS=()
on_exit_cleanup() { CLEANUP_ACTIONS+=("$*"); }
run_cleanup() {
  local action
  for action in "${CLEANUP_ACTIONS[@]+"${CLEANUP_ACTIONS[@]}"}"; do
    eval "$action" >/dev/null 2>&1 || echo "• cleanup failed: $action" >&2
  done
}
trap run_cleanup EXIT

# LiteLLM writes request logs asynchronously and re-creates the customer row when it does,
# so delete, wait for pending writes, then delete again.
delete_litellm_customer() {
  local body
  body=$(jq -cn --arg e "$1" '{user_ids: [$e]}')
  litellm_admin POST /customer/delete "$body" >/dev/null 2>&1 || true
  sleep 5
  litellm_admin POST /customer/delete "$body" >/dev/null 2>&1 || true
}

# Creates a LiteLLM customer with the given spend, deleted on exit.
create_temporary_customer() {
  local email=$1 spend=$2
  litellm_admin POST /customer/new "$(jq -n --arg e "$email" --argjson s "$spend" '{user_id: $e, spend: $s}')" >/dev/null \
    || fail "could not create customer $email"
  on_exit_cleanup delete_litellm_customer "$email"
}

unique_smoke_email() { echo "smoke-$(date +%s)-$RANDOM@skolagaudi.cz"; }

# Creates a regular Open WebUI user, deleted on exit, and signs it in: sets TEMP_USER_TOKEN.
# Call it directly, never inside $(...): a subshell would lose the cleanup registration.
create_temporary_staff_user() {
  local email=$1 password user_id
  password=$(openssl rand -hex 16)
  user_id=$(openwebui_admin POST /api/v1/auths/add \
    "$(jq -n --arg e "$email" --arg p "$password" '{name: $e, email: $e, password: $p, role: "user"}')" | jq -er .id) \
    || fail "could not create temporary user $email"
  on_exit_cleanup openwebui_admin DELETE "/api/v1/users/$user_id"
  TEMP_USER_TOKEN=$(api_request "" POST "$OPENWEBUI_URL/api/v1/auths/signin" \
    "$(jq -n --arg e "$email" --arg p "$password" '{email: $e, password: $p}')" | jq -er .token) \
    || fail "could not sign in temporary user $email"
}

# Creates a regular Open WebUI account for trying things in the browser, deleted on exit.
# Call it directly, never inside $(...): a subshell would lose the cleanup registration.
create_demo_staff_account() {
  local email=$1 password=$2 name=$3 user_id
  user_id=$(openwebui_admin POST /api/v1/auths/add \
    "$(jq -n --arg e "$email" --arg p "$password" --arg n "$name" '{name: $n, email: $e, password: $p, role: "user"}')" \
    | jq -er .id) || fail "could not create the demo account"
  on_exit_cleanup openwebui_admin DELETE "/api/v1/users/$user_id"
}

wait_until_demo_is_done() {
  read -r -p "Press Enter when done (the account is then deleted)… " _
  info "deleting the demo account"
}

# Each application has a database and a login role of the same name (postgres/ensure-databases.sh).
readonly APP_DATABASES="litellm openwebui"
# Open WebUI's own files: uploads and the vector index. cache/ (downloaded models) is re-created on start.
readonly OPENWEBUI_VOLUME="open-webui-data"

compose_volume_name() { compose config --format json | jq -er --arg v "$1" '.volumes[$v].name'; }
# Backup and restore use the postgres image for tar, so they need no extra image.
tools_image() { compose config --format json | jq -er '.services.postgres.image'; }

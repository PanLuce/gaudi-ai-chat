# Shared helpers for the stack scripts. Source it, don't run it.
# Scripts read .env, which the Claude Code sandbox may not read: run them outside the sandbox.

# Sourced once even when a script sources both bootstrap.sh and test-lib.sh (readonly values, cleanups).
[ -z "${GAUDI_LIB_SOURCED:-}" ] || return 0
GAUDI_LIB_SOURCED=1

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$REPO_ROOT/.env"
LITELLM_URL="http://127.0.0.1:4000"

# Default monthly budget of every staff member; litellm/config.yaml refers to it by id.
readonly STAFF_BUDGET_ID="staff-monthly"
# The model behind Chat's image button (litellm/config.yaml).
readonly IMAGE_MODEL="gemini-image"
# The text models litellm/config.yaml offers and Chat shows (sorted).
readonly EXPECTED_TEXT_MODELS="claude-haiku claude-opus claude-sonnet"
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

# Deletes a LiteLLM key by its alias, so a failed cleanup never prints the key itself.
delete_litellm_key_alias() {
  litellm_admin POST /key/delete "$(jq -cn --arg a "$1" '{key_aliases: [$a]}')" >/dev/null
}

# Each application has a database and a login role of the same name (postgres/ensure-databases.sh).
readonly APP_DATABASES="litellm openwebui"
# Open WebUI's own files: uploads and the vector index. cache/ (downloaded models) is re-created on start.
readonly OPENWEBUI_VOLUME="open-webui-data"
BACKUP_ROOT="${BACKUP_ROOT:-$REPO_ROOT/backups}" # backup.sh writes here, offsite.sh uploads from here

compose_volume_name() { compose config --format json | jq -er --arg v "$1" '.volumes[$v].name'; }
# Backup and restore use the postgres image for tar, so they need no extra image.
tools_image() { compose config --format json | jq -er '.services.postgres.image'; }

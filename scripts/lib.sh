# Shared helpers for the stack scripts. Source it, don't run it.
# Scripts read .env, which the Claude Code sandbox may not read: run them outside the sandbox.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$REPO_ROOT/.env"
LITELLM_URL="http://127.0.0.1:4000"
OPENWEBUI_URL="${OPENWEBUI_URL:-http://127.0.0.1:3000}"

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
}

compose() { docker compose --project-directory "$REPO_ROOT" "$@"; }

litellm_admin() {
  local method=$1 path=$2 body=${3:-}
  curl -sS --fail-with-body -X "$method" "$LITELLM_URL$path" \
    -H "Authorization: Bearer $LITELLM_MASTER_KEY" -H 'Content-Type: application/json' \
    ${body:+-d "$body"}
}

openwebui_admin() {
  local method=$1 path=$2 body=${3:-}
  [ -n "${OPENWEBUI_ADMIN_API_KEY:-}" ] || fail "OPENWEBUI_ADMIN_API_KEY is not set in .env (see README: Admin API key)"
  curl -sS --fail-with-body -X "$method" "$OPENWEBUI_URL$path" \
    -H "Authorization: Bearer $OPENWEBUI_ADMIN_API_KEY" -H 'Content-Type: application/json' \
    ${body:+-d "$body"}
}

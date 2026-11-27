#!/usr/bin/env bash
# Checks that a fresh Chat (Open WebUI) creates its admin from .env and closes sign-up, so nobody else
# can take the admin account in the minutes after the first start, and that bootstrap.sh then makes
# the admin API key for its own steps without anyone copying it from the UI. Runs a throwaway Chat container
# with an empty database of its own; the running stack and its data are not touched. Free.
set -euo pipefail
. "$(dirname "$0")/test-lib.sh"
. "$(dirname "$0")/bootstrap.sh"

readonly CHAT_SERVICE="open-webui"
readonly TAG=$(smoke_tag admin)
readonly ADMIN_EMAIL="$TAG@skolagaudi.cz"
ADMIN_PASSWORD=""
CHAT_URL=""

# The admin settings exactly as docker-compose.yml hands them to Chat, filled with test values, and
# whether Chat allows API keys at all (bootstrap needs one).
chat_admin_env() {
  WEBUI_ADMIN_EMAIL="$ADMIN_EMAIL" WEBUI_ADMIN_PASSWORD="$ADMIN_PASSWORD" compose config --format json \
    | jq -er --arg s "$CHAT_SERVICE" '.services[$s].environment
        | {WEBUI_ADMIN_EMAIL, WEBUI_ADMIN_PASSWORD, ENABLE_API_KEYS}
        | if (.WEBUI_ADMIN_EMAIL // "") == "" or (.WEBUI_ADMIN_PASSWORD // "") == ""
          then error("docker-compose.yml does not pass WEBUI_ADMIN_EMAIL and WEBUI_ADMIN_PASSWORD to Chat") else . end
        | to_entries[] | "\(.key)=\(.value)"'
}

remove_container() { docker rm -f "$1" >/dev/null 2>&1; }

start_fresh_chat() {
  local image env_file port
  image=$(compose config --format json | jq -er --arg s "$CHAT_SERVICE" '.services[$s].image')
  env_file=$(mktemp)
  on_exit_cleanup rm -f "$env_file"
  chat_admin_env > "$env_file" || fail "docker-compose.yml does not pass the admin settings to Chat"
  printf 'WEBUI_SECRET_KEY=%s\n' "$(openssl rand -hex 24)" >> "$env_file"
  # A fresh Chat downloads its search model first (minutes, at HuggingFace's pace); sign-in needs none of it.
  printf 'OFFLINE_MODE=true\nHF_HUB_OFFLINE=1\n' >> "$env_file"
  on_exit_cleanup remove_container "$TAG"
  docker run -d --name "$TAG" --env-file "$env_file" -p 127.0.0.1::8080 "$image" >/dev/null \
    || fail "could not start a throwaway Chat from $image"
  port=$(docker port "$TAG" 8080/tcp | head -1 | cut -d: -f2)
  CHAT_URL="http://127.0.0.1:$port"
  wait_until_chat_answers
}

chat_answers() { curl -sf "$CHAT_URL/health" >/dev/null 2>&1; }

wait_until_chat_answers() {
  retry_until 90 2 chat_answers || fail "the throwaway Chat did not start within 3 minutes"
}

assert_admin_from_env_can_sign_in() {
  local role
  role=$(api_request "" POST "$CHAT_URL/api/v1/auths/signin" \
    "$(jq -cn --arg e "$ADMIN_EMAIL" --arg p "$ADMIN_PASSWORD" '{email: $e, password: $p}')" 2>/dev/null | jq -r '.role // empty' || true)
  [ "$role" = "admin" ] || fail "the admin from .env cannot sign in to a fresh Chat (role: ${role:-none})"
  pass "a fresh Chat has its admin from .env right after the first start"
}

assert_sign_up_is_closed() {
  local enabled
  enabled=$(curl -sf "$CHAT_URL/api/config" | jq -r '.features.enable_signup')
  [ "$enabled" = "false" ] || fail "sign-up is still open in a fresh Chat (enable_signup: $enabled)"
  pass "nobody else can sign up to take the admin account"
}

admin_key_in_env_file() { grep '^OPENWEBUI_ADMIN_API_KEY=' "$ENV_FILE" | cut -d= -f2-; }

# bootstrap.sh signs in as the admin from .env and keeps the key it makes in .env; a second run reuses it.
assert_bootstrap_makes_the_admin_key() {
  local first
  ENV_FILE=$(mktemp)
  on_exit_cleanup rm -f "$ENV_FILE"
  printf 'OPENWEBUI_ADMIN_API_KEY=\n' > "$ENV_FILE"
  OPENWEBUI_URL=$CHAT_URL WEBUI_ADMIN_EMAIL=$ADMIN_EMAIL WEBUI_ADMIN_PASSWORD=$ADMIN_PASSWORD OPENWEBUI_ADMIN_API_KEY=""
  ensure_openwebui_admin_key >/dev/null
  first=$(admin_key_in_env_file)
  [ -n "$first" ] || fail "bootstrap did not keep an admin API key in .env"
  [ "$(openwebui_admin_status /api/v1/auths/admin/config)" = 200 ] || fail "the admin API key bootstrap made does not work in Chat"
  ensure_openwebui_admin_key >/dev/null
  [ "$(admin_key_in_env_file)" = "$first" ] || fail "a second bootstrap replaced a working admin API key"
  pass "bootstrap makes Chat's admin API key itself and keeps it on the next run"
}

main() {
  require_tools docker curl jq openssl
  load_env
  ADMIN_PASSWORD=$(openssl rand -hex 16)
  start_fresh_chat
  assert_admin_from_env_can_sign_in
  assert_sign_up_is_closed
  assert_bootstrap_makes_the_admin_key
}

main "$@"

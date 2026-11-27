#!/usr/bin/env bash
# Smoke checks against the running stack, through the ports people actually use.
# Usage: scripts/smoke.sh   (free: nothing reaches a provider; a real answer is tried by hand, see the guide)
# Exit code is non-zero on the first failing check.
set -euo pipefail
. "$(dirname "$0")/test-lib.sh"

readonly TERMINAL_ID="open-terminal"
readonly TERMINAL_COMMAND='{"command":"echo smoke-terminal-ok"}'

readonly ONE_SHOT_SERVICES="db-init"

# Checks every long-running service the compose file defines, so a stopped one fails too.
check_all_services_healthy() {
  local service health unhealthy=""
  for service in $(compose config --services); do
    case " $ONE_SHOT_SERVICES " in *" $service "*) continue ;; esac
    health=$(compose ps --format '{{.Health}}' "$service" 2>/dev/null)
    [ "$health" = "healthy" ] || unhealthy="$unhealthy $service(${health:-not running})"
  done
  [ -z "$unhealthy" ] || fail "services not healthy:$unhealthy"
  pass "all services healthy"
}

# Caddy is the only way in: it adds the security headers, so their presence proves the route.
check_openwebui_is_served_through_caddy() {
  local headers
  headers=$(curl -sS -o /dev/null -D - --max-time 10 "$OPENWEBUI_URL/health" 2>/dev/null || true)
  grep -q '^HTTP/[0-9.]* 200' <<<"$headers" || fail "Open WebUI is not reachable at $OPENWEBUI_URL"
  grep -qi '^x-content-type-options: nosniff' <<<"$headers" || fail "$OPENWEBUI_URL is not served through Caddy (no security headers)"
  pass "Open WebUI is served through Caddy at $OPENWEBUI_URL"
}

# Chat answers stream over a WebSocket; the proxy must pass the upgrade through.
check_websocket_passes_through_caddy() {
  local status
  status=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 \
    -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' \
    -H "Sec-WebSocket-Key: $(openssl rand -base64 16)" \
    "$OPENWEBUI_URL/ws/socket.io/?EIO=4&transport=websocket" 2>/dev/null || true)
  [ "$status" = "101" ] || fail "WebSocket upgrade through $OPENWEBUI_URL returned $status, expected 101"
  pass "chat streaming (WebSocket) passes through Caddy"
}

# Links in e-mails and OAuth redirects are built from this address.
check_openwebui_knows_its_public_address() {
  local configured
  configured=$(openwebui_admin GET /api/v1/auths/admin/config | jq -r '.WEBUI_URL')
  [ "$configured" = "$OPENWEBUI_URL" ] || fail "Open WebUI thinks its address is $configured, expected $OPENWEBUI_URL"
  pass "Open WebUI knows its public address $OPENWEBUI_URL"
}

# Who else may use the terminal is the admin's configuration; the admin must always have it.
check_admin_runs_commands_in_the_terminal() {
  local terminals output
  terminals=$(openwebui_admin GET /api/v1/machines/ | jq -r '.[].id' | xargs)
  grep -qw -- "$TERMINAL_ID" <<<"$terminals" || fail "admin does not see the terminal $TERMINAL_ID (sees: [$terminals])"
  output=$(openwebui_admin POST "/api/v1/machines/$TERMINAL_ID/execute?wait=10" "$TERMINAL_COMMAND" 2>&1 || true)
  grep -q "smoke-terminal-ok" <<<"$output" || fail "admin cannot run a command in the terminal: $(head -c 300 <<<"$output")"
  pass "an admin runs commands in the terminal through Open WebUI"
}



check_openwebui_offers_claude_models() {
  local offered
  offered=$(openwebui_admin GET /api/models | jq -r '.data[].id' | grep '^claude-' | sort | xargs)
  [ "$offered" = "$EXPECTED_TEXT_MODELS" ] || fail "Open WebUI offers [$offered], expected [$EXPECTED_TEXT_MODELS]"
  pass "Open WebUI offers $EXPECTED_TEXT_MODELS"
}




# One staff account for two facts. Which models staff see is the admin's configuration; only the default
# one must be there, otherwise nobody can chat (checked as a regular user, since admins see every model).
# Then the same person goes over budget. Free: the budget check runs before any provider call, and a
# blocked request also proves that Open WebUI forwards the user's e-mail, since LiteLLM finds the budget by it.
check_staff_member() {
  local email default offered
  default=$(openwebui_admin GET /api/v1/configs/models | jq -r '.DEFAULT_MODELS // empty' | cut -d, -f1)
  [ -n "$default" ] || fail "Open WebUI has no default model"
  email=$(unique_smoke_email)
  create_temporary_staff_user "$email"
  offered=$(api_request "$TEMP_USER_TOKEN" GET "$OPENWEBUI_URL/api/models" | jq -r '.data[].id' | xargs)
  grep -qw -- "$default" <<<"$offered" || fail "a staff member cannot use the default model $default (sees: $offered)"
  pass "a staff member can use the default model $default"
  create_temporary_customer "$email" 6
  assert_blocked_by_budget /api/chat/completions "$SMALL_CHAT" "$email"
  pass "a user over budget is blocked in Open WebUI with a Czech message"
}

assert_blocked_by_budget() {
  local path=$1 request=$2 email=$3 response
  response=$(api_request "$TEMP_USER_TOKEN" POST "$OPENWEBUI_URL$path" "$request" 2>/dev/null || true)
  assert_personal_budget_message "$response" "$email"
}



run_free_checks() {
  check_all_services_healthy
  check_openwebui_is_served_through_caddy
  check_websocket_passes_through_caddy
  check_openwebui_knows_its_public_address
  check_openwebui_offers_claude_models
  check_admin_runs_commands_in_the_terminal
  check_staff_member
}

main() {
  [ $# -eq 0 ] || fail "usage: scripts/smoke.sh (no options; a real answer and image are tried by hand, docs/nasazeni.html)"
  require_tools docker curl jq openssl
  load_env
  run_free_checks
}

main "$@"

#!/usr/bin/env bash
# Smoke checks against the running stack, through the ports people actually use.
# Usage: scripts/smoke.sh   (free: nothing reaches a provider; a real answer is tried by hand, see the guide)
# Exit code is non-zero on the first failing check.
set -euo pipefail
. "$(dirname "$0")/test-lib.sh"

readonly IMAGE_MODEL="gemini-image"
readonly SMALL_CHAT='{"model":"claude-haiku","stream":false,"max_tokens":5,"messages":[{"role":"user","content":"ahoj"}]}'
readonly TERMINAL_ID="open-terminal"
readonly TERMINAL_COMMAND='{"command":"echo smoke-terminal-ok"}'
readonly SMALL_IMAGE='{"prompt":"a small red apple on a white table"}'

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
  local email other default offered
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
  # A custom "user" parameter (allowed in chat settings) must not move spend to another identity.
  other=$(unique_smoke_email)
  on_exit_cleanup delete_litellm_customer "$other" # exists only if the dodge ever worked
  assert_blocked_by_budget /api/chat/completions "$(jq -c --arg u "$other" '.user = $u' <<<"$SMALL_CHAT")" "$email"
  pass "the budget cannot be dodged with a custom 'user' parameter"
  assert_image_blocked_by_budget "$email"
  pass "a user over budget cannot generate images either"
}

# Open WebUI hides the reason of a failed image request, so read it from LiteLLM's request log.
# Cost note: free only while the budget check works; if it broke for images alone, this would buy
# one image (~0.045 USD). The chat checks above run first and stop the run on a general budget failure.
assert_image_blocked_by_budget() {
  local email=$1
  ! api_request "$TEMP_USER_TOKEN" POST "$OPENWEBUI_URL/api/v1/images/generations" "$SMALL_IMAGE" >/dev/null 2>&1 \
    || fail "overspent user got an image"
  retry_until 10 2 image_refused_for_budget "$email" \
    || fail "image request of overspent user was not refused by the budget check" # the request log is written asynchronously
}

image_refused_for_budget() {
  local today
  today=$(date -u +%Y-%m-%d)
  litellm_admin GET "/spend/logs/v2?start_date=$today&end_date=$(date -u -v+1d +%Y-%m-%d 2>/dev/null || date -u -d tomorrow +%Y-%m-%d)&page_size=100" \
    | jq -e --arg e "$1" --arg m "$IMAGE_MODEL" 'any(.data[]; .end_user == $e and .model_group == $m
        and .status == "failure" and .spend == 0
        and ((.metadata.error_information.error_message // "") | contains("ExceededBudget")))' >/dev/null
}

# "2026-12-01T00:00:00Z" -> "1. 12. 2026". Resets happen at midnight UTC, so the UTC day is the Prague day.
staff_budget_reset_day() {
  litellm_admin POST /budget/info "{\"budgets\":[\"$STAFF_BUDGET_ID\"]}" \
    | jq -r '.[0].budget_reset_at[0:10] | split("-") | map(tonumber) | "\(.[2]). \(.[1]). \(.[0])"'
}

# The person sees a Czech message with a code for the admin, never their e-mail or LiteLLM internals.
assert_blocked_by_budget() {
  local path=$1 request=$2 email=$3 response
  response=$(api_request "$TEMP_USER_TOKEN" POST "$OPENWEBUI_URL$path" "$request" 2>/dev/null || true)
  grep -q "Tvůj rozpočet na AI chat je vyčerpaný" <<<"$response" && grep -q "(kód: rozpocet)" <<<"$response" \
    || fail "overspent user did not get the Czech budget message: $(head -c 300 <<<"$response")"
  grep -qF "využitý celých $STAFF_BUDGET_USD \$" <<<"$response" \
    || fail "the budget message does not name the \$$STAFF_BUDGET_USD budget: $(head -c 300 <<<"$response")"
  grep -qF "Rozpočet se obnoví $(staff_budget_reset_day)." <<<"$response" \
    || fail "the budget message does not say when the budget resets ($(staff_budget_reset_day)): $(head -c 300 <<<"$response")"
  ! grep -qE "$email|ExceededBudget" <<<"$response" \
    || fail "the budget message shows the e-mail or LiteLLM internals: $(head -c 300 <<<"$response")"
}

# The school's budget lives on the key Open WebUI uses. A temporary key with spend over its budget
# gets the same error. Free only if LiteLLM really recorded the spend, so that is checked before
# the call: otherwise the request would reach the provider.
check_school_budget_message_is_czech() {
  local alias key response
  alias=$(smoke_tag key)
  on_exit_cleanup delete_litellm_key_alias "$alias"
  key=$(litellm_admin POST /key/generate "$(jq -cn --arg a "$alias" '{key_alias: $a, max_budget: 1, spend: 2, models: ["claude-haiku"]}')" \
    | jq -er .key) || fail "could not create temporary key $alias"
  [ "$(litellm_as "$key" GET /key/info | jq -r '.info.spend')" = "2.0" ] \
    || fail "temporary key $alias has no recorded spend; refusing a call that could be paid"
  response=$(litellm_as "$key" POST /v1/chat/completions "$SMALL_CHAT" 2>/dev/null || true)
  grep -q "AI chat má tento měsíc vyčerpaný rozpočet celé školy" <<<"$response" && grep -q "(kód: rozpocet-skoly)" <<<"$response" \
    || fail "a key over budget did not get the Czech school budget message: $(head -c 300 <<<"$response")"
  ! grep -qE "Key=|Budget has been exceeded" <<<"$response" \
    || fail "the school budget message shows LiteLLM internals: $(head -c 300 <<<"$response")"
  pass "when the school budget runs out, people get a Czech message"
}

# Free: LiteLLM rejects an unknown model before any provider call. Sent with the key Open WebUI
# uses, so this is the error people would see if a model disappeared from litellm/config.yaml.
check_config_error_message_is_czech() {
  local response
  response=$(litellm_as "$OPENWEBUI_LITELLM_KEY" POST /v1/chat/completions \
    '{"model":"smoke-no-such-model","max_tokens":5,"messages":[{"role":"user","content":"ahoj"}]}' 2>/dev/null || true)
  grep -q "Chyba v nastavení AI chatu" <<<"$response" && grep -q "(kód: nastaveni)" <<<"$response" \
    || fail "an unknown model did not get the Czech settings message: $(head -c 300 <<<"$response")"
  pass "a broken model setting shows a Czech message"
}

# Provider errors cannot be caused for free, so the mapping runs against LiteLLM's own exception
# classes inside the running LiteLLM container, without network.
check_provider_errors_are_czech() {
  compose exec -T litellm python - <<'PY_CHECK' || fail "a provider error has no Czech message"
import sys, httpx, litellm
sys.path.insert(0, "/app")
from czech_errors import czech_message

forbidden = httpx.Response(403, request=httpx.Request("POST", "https://provider"))
cases = [
    ("pretizeno", litellm.RateLimitError("rate limited", "anthropic", "claude")),
    ("pretizeno", litellm.ServiceUnavailableError("unavailable", "anthropic", "claude")),
    ("pretizeno", litellm.InternalServerError("AnthropicException - Overloaded", "anthropic", "claude")),
    ("cas", litellm.Timeout("timed out", "claude", "anthropic")),
    ("dlouha-konverzace", litellm.ContextWindowExceededError("prompt is too long", "claude", "anthropic")),
    ("odmitnuto", litellm.ContentPolicyViolationError("blocked", "claude", "anthropic")),
    ("nastaveni", litellm.AuthenticationError("invalid x-api-key", "anthropic", "claude")),
    ("nastaveni", litellm.PermissionDeniedError("no access", "anthropic", "claude", forbidden)),
    ("nastaveni", litellm.NotFoundError("model not found", "claude", "anthropic")),
    ("jina", litellm.BadRequestError("max_tokens is too large", "claude", "anthropic")),
    ("jina", litellm.APIConnectionError("connection reset", "anthropic", "claude")),
    ("jina", ValueError("anything else")),
]
failed = False
for wanted, exc in cases:
    got = czech_message(exc)
    if not got or got[0] != wanted or not got[1]:
        failed = True
        print(f"✗ {type(exc).__name__}: got {got}, wanted code {wanted}", file=sys.stderr)
sys.exit(1 if failed else 0)
PY_CHECK
  pass "every kind of provider error has a Czech message"
}


run_free_checks() {
  check_all_services_healthy
  check_openwebui_is_served_through_caddy
  check_websocket_passes_through_caddy
  check_openwebui_knows_its_public_address
  check_openwebui_offers_claude_models
  check_admin_runs_commands_in_the_terminal
  check_staff_member
  check_school_budget_message_is_czech
  check_config_error_message_is_czech
  check_provider_errors_are_czech
}

main() {
  [ $# -eq 0 ] || fail "usage: scripts/smoke.sh (no options; a real answer and image are tried by hand, docs/nasazeni.html)"
  require_tools docker curl jq openssl
  load_env
  run_free_checks
}

main "$@"

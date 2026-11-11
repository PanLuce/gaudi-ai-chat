#!/usr/bin/env bash
# Smoke checks against the running stack, through the ports people actually use.
# Usage: scripts/smoke.sh          free checks only
#        scripts/smoke.sh --paid   also checks that spend real provider credit (one tiny request each)
# Exit code is non-zero on the first failing check.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

readonly EXPECTED_TEXT_MODELS="claude-haiku claude-opus claude-sonnet"

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

check_openwebui_stores_data_in_postgres() {
  local has_user_table
  has_user_table=$(compose exec -T postgres psql -U postgres -d openwebui -tAc \
    "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'user'" 2>/dev/null || true)
  [ "$has_user_table" = "1" ] || fail "Open WebUI tables not found in Postgres database 'openwebui'"
  pass "Open WebUI stores its data in Postgres"
}

# A fixed key keeps sessions valid when the container is recreated (e.g. on upgrade).
check_openwebui_has_fixed_secret_key() {
  local configured
  configured=$(compose exec -T open-webui printenv WEBUI_SECRET_KEY 2>/dev/null || true)
  [ -n "$configured" ] && [ "$configured" = "${WEBUI_SECRET_KEY:-}" ] \
    || fail "Open WebUI does not run with WEBUI_SECRET_KEY from .env"
  pass "Open WebUI runs with the fixed WEBUI_SECRET_KEY"
}

check_openwebui_offers_claude_models() {
  local offered
  offered=$(openwebui_admin GET /api/models | jq -r '.data[].id' | grep '^claude-' | sort | xargs)
  [ "$offered" = "$EXPECTED_TEXT_MODELS" ] || fail "Open WebUI offers [$offered], expected [$EXPECTED_TEXT_MODELS]"
  pass "Open WebUI offers $EXPECTED_TEXT_MODELS"
}

# Open WebUI hides models without access rules from regular users, so check as one of them.
check_staff_member_sees_claude_models() {
  local offered
  create_temporary_staff_user "$(unique_smoke_email)"
  offered=$(api_request "$TEMP_USER_TOKEN" GET "$OPENWEBUI_URL/api/models" | jq -r '.data[].id' | grep '^claude-' | sort | xargs)
  [ "$offered" = "$EXPECTED_TEXT_MODELS" ] || fail "a staff member sees [$offered], expected [$EXPECTED_TEXT_MODELS]"
  pass "a staff member sees $EXPECTED_TEXT_MODELS"
}

check_default_staff_budget() {
  local budget
  budget=$(litellm_admin POST /budget/info "{\"budgets\":[\"$STAFF_BUDGET_ID\"]}" 2>/dev/null \
    | jq -r '.[0] | "\(.max_budget) \(.budget_duration)"' || true)
  [ "$budget" = "$STAFF_BUDGET_USD.0 30d" ] || fail "staff budget '$STAFF_BUDGET_ID' is [$budget], expected [$STAFF_BUDGET_USD.0 30d]"
  pass "every staff member gets \$$STAFF_BUDGET_USD per 30 days"
}

# Free: the budget check runs before any provider call. A blocked request also proves that
# Open WebUI forwards the user's e-mail, since LiteLLM can only find the budget through it.
check_overspent_user_is_blocked_in_openwebui() {
  local email response
  email=$(unique_smoke_email)
  create_temporary_staff_user "$email"
  litellm_admin POST /customer/new "$(jq -n --arg e "$email" '{user_id: $e, spend: 6}')" >/dev/null
  on_exit_cleanup litellm_admin POST /customer/delete "'$(jq -cn --arg e "$email" '{user_ids: [$e]}')'"
  assert_chat_blocked_by_budget '{"model":"claude-haiku","stream":false,"max_tokens":5,"messages":[{"role":"user","content":"ahoj"}]}'
  pass "a user over budget is blocked in Open WebUI"
  # A custom "user" parameter (allowed in chat settings) must not move spend to another identity.
  assert_chat_blocked_by_budget '{"model":"claude-haiku","stream":false,"max_tokens":5,"user":"someone-else@skolagaudi.cz","messages":[{"role":"user","content":"ahoj"}]}'
  pass "the budget cannot be dodged with a custom 'user' parameter"
}

assert_chat_blocked_by_budget() {
  local request=$1 response
  response=$(api_request "$TEMP_USER_TOKEN" POST "$OPENWEBUI_URL/api/chat/completions" "$request" 2>/dev/null || true)
  grep -q "ExceededBudget" <<<"$response" \
    || fail "overspent user was not blocked by budget: $(head -c 300 <<<"$response")"
}

check_haiku_answers_in_openwebui() {
  local response answer
  response=$(openwebui_admin POST /api/chat/completions \
    '{"model":"claude-haiku","stream":false,"max_tokens":20,"messages":[{"role":"user","content":"Odpověz jedním slovem: ahoj"}]}') \
    || fail "claude-haiku request failed: $(jq -r '.error.message // .detail // .' <<<"$response" | head -c 300)"
  answer=$(jq -r '.choices[0].message.content // empty' <<<"$response")
  [ -n "$answer" ] || fail "claude-haiku returned no answer through Open WebUI"
  pass "claude-haiku answers through Open WebUI: $answer"
}

run_free_checks() {
  check_all_services_healthy
  check_openwebui_stores_data_in_postgres
  check_openwebui_has_fixed_secret_key
  check_openwebui_offers_claude_models
  check_staff_member_sees_claude_models
  check_default_staff_budget
  check_overspent_user_is_blocked_in_openwebui
}

# Paid: a real answer for a staff member is charged to that person's e-mail.
check_spend_is_charged_to_the_staff_member() {
  local email spend
  email=$(unique_smoke_email)
  create_temporary_staff_user "$email"
  on_exit_cleanup litellm_admin POST /customer/delete "'$(jq -cn --arg e "$email" '{user_ids: [$e]}')'"
  api_request "$TEMP_USER_TOKEN" POST "$OPENWEBUI_URL/api/chat/completions" \
    '{"model":"claude-haiku","stream":false,"max_tokens":5,"messages":[{"role":"user","content":"ahoj"}]}' >/dev/null \
    || fail "staff member's request failed"
  sleep 5 # LiteLLM writes spend asynchronously
  spend=$(litellm_admin GET "/customer/info?end_user_id=$email" | jq -r '.spend // 0')
  awk -v s="$spend" 'BEGIN { exit !(s > 0) }' || fail "no spend recorded for $email"
  pass "spend is charged to the staff member ($spend USD)"
}

run_paid_checks() {
  check_haiku_answers_in_openwebui
  check_spend_is_charged_to_the_staff_member
}

main() {
  require_tools docker curl jq
  load_env
  run_free_checks
  case "${1:-}" in
    --paid) run_paid_checks ;;
    "") info "paid checks skipped (run with --paid once the provider account has credit)" ;;
    *) fail "unknown option: $1" ;;
  esac
}

main "$@"

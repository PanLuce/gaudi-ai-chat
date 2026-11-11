#!/usr/bin/env bash
# Smoke checks against the running stack, through the ports people actually use.
# Usage: scripts/smoke.sh          free checks only
#        scripts/smoke.sh --paid   also checks that spend real provider credit (one tiny request each)
# Exit code is non-zero on the first failing check.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

readonly EXPECTED_TEXT_MODELS="claude-haiku claude-opus claude-sonnet"
readonly IMAGE_MODEL="gemini-image"
readonly SMALL_CHAT='{"model":"claude-haiku","stream":false,"max_tokens":5,"messages":[{"role":"user","content":"ahoj"}]}'
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

# Which models staff see is the admin's configuration; only the default one must be there,
# otherwise nobody can chat. Checked as a regular user, since admins see every model.
check_staff_member_sees_default_model() {
  local default offered
  default=$(openwebui_admin GET /api/v1/configs/models | jq -r '.DEFAULT_MODELS // empty' | cut -d, -f1)
  [ -n "$default" ] || fail "Open WebUI has no default model"
  create_temporary_staff_user "$(unique_smoke_email)"
  offered=$(api_request "$TEMP_USER_TOKEN" GET "$OPENWEBUI_URL/api/models" | jq -r '.data[].id' | xargs)
  grep -qw -- "$default" <<<"$offered" || fail "a staff member cannot use the default model $default (sees: $offered)"
  pass "a staff member can use the default model $default"
}

check_openwebui_generates_images_through_litellm() {
  local config
  config=$(openwebui_admin GET /api/v1/images/config | jq -c \
    '{ENABLE_IMAGE_GENERATION, IMAGE_GENERATION_ENGINE, IMAGES_OPENAI_API_BASE_URL, IMAGE_GENERATION_MODEL}')
  [ "$config" = '{"ENABLE_IMAGE_GENERATION":true,"IMAGE_GENERATION_ENGINE":"openai","IMAGES_OPENAI_API_BASE_URL":"http://litellm:4000/v1","IMAGE_GENERATION_MODEL":"gemini-image"}' ] \
    || fail "Open WebUI image generation is $config"
  pass "Open WebUI generates images with $IMAGE_MODEL through LiteLLM"
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
  create_temporary_customer "$email" 6
  assert_blocked_by_budget /api/chat/completions "$SMALL_CHAT"
  pass "a user over budget is blocked in Open WebUI"
  # A custom "user" parameter (allowed in chat settings) must not move spend to another identity.
  assert_blocked_by_budget /api/chat/completions "$(jq -c '.user = "someone-else@skolagaudi.cz"' <<<"$SMALL_CHAT")"
  pass "the budget cannot be dodged with a custom 'user' parameter"
  assert_image_blocked_by_budget "$email"
  pass "a user over budget cannot generate images either"
}

# Open WebUI hides the reason of a failed image request, so read it from LiteLLM's request log.
# Cost note: free only while the budget check works; if it broke for images alone, this would buy
# one image (~0.045 USD). The chat checks above run first and stop the run on a general budget failure.
assert_image_blocked_by_budget() {
  local email=$1 attempt
  ! api_request "$TEMP_USER_TOKEN" POST "$OPENWEBUI_URL/api/v1/images/generations" "$SMALL_IMAGE" >/dev/null 2>&1 \
    || fail "overspent user got an image"
  for attempt in 1 2 3 4 5 6 7 8 9 10; do # LiteLLM writes its request log asynchronously
    image_refused_for_budget "$email" && return 0
    sleep 2
  done
  fail "image request of overspent user was not refused by the budget check"
}

image_refused_for_budget() {
  local today
  today=$(date -u +%Y-%m-%d)
  litellm_admin GET "/spend/logs/v2?start_date=$today&end_date=$(date -u -v+1d +%Y-%m-%d 2>/dev/null || date -u -d tomorrow +%Y-%m-%d)&page_size=100" \
    | jq -e --arg e "$1" --arg m "$IMAGE_MODEL" 'any(.data[]; .end_user == $e and .model_group == $m
        and .status == "failure" and .spend == 0
        and ((.metadata.error_information.error_message // "") | contains("ExceededBudget")))' >/dev/null
}

assert_blocked_by_budget() {
  local path=$1 request=$2 response
  response=$(api_request "$TEMP_USER_TOKEN" POST "$OPENWEBUI_URL$path" "$request" 2>/dev/null || true)
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
  check_staff_member_sees_default_model
  check_openwebui_generates_images_through_litellm
  check_default_staff_budget
  check_overspent_user_is_blocked_in_openwebui
}

# Paid: a real answer for a staff member is charged to that person's e-mail.
check_spend_is_charged_to_the_staff_member() {
  local email spend
  email=$(unique_smoke_email)
  create_temporary_staff_user "$email"
  on_exit_cleanup delete_litellm_customer "$email"
  api_request "$TEMP_USER_TOKEN" POST "$OPENWEBUI_URL/api/chat/completions" \
    '{"model":"claude-haiku","stream":false,"max_tokens":5,"messages":[{"role":"user","content":"ahoj"}]}' >/dev/null \
    || fail "staff member's request failed"
  sleep 5 # LiteLLM writes spend asynchronously
  spend=$(litellm_admin GET "/customer/info?end_user_id=$email" | jq -r '.spend // 0')
  awk -v s="$spend" 'BEGIN { exit !(s > 0) }' || fail "no spend recorded for $email"
  pass "spend is charged to the staff member ($spend USD)"
}

# Paid (~0.045 USD): a staff member gets a real image, charged to their budget.
check_staff_member_gets_an_image() {
  local email response spend
  email=$(unique_smoke_email)
  create_temporary_staff_user "$email"
  on_exit_cleanup delete_litellm_customer "$email"
  response=$(api_request "$TEMP_USER_TOKEN" POST "$OPENWEBUI_URL/api/v1/images/generations" "$SMALL_IMAGE") \
    || fail "image generation failed: $(head -c 300 <<<"$response")"
  jq -e '.[0].url' <<<"$response" >/dev/null || fail "no image in response: $(head -c 300 <<<"$response")"
  sleep 5 # LiteLLM writes spend asynchronously
  spend=$(litellm_admin GET "/customer/info?end_user_id=$email" | jq -r '.spend // 0')
  awk -v s="$spend" 'BEGIN { exit !(s > 0) }' || fail "image was not charged to $email (spend $spend)"
  pass "a staff member gets an image from $IMAGE_MODEL, charged $spend USD"
}

run_paid_checks() {
  check_haiku_answers_in_openwebui
  check_spend_is_charged_to_the_staff_member
  check_staff_member_gets_an_image
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

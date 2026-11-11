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
}

run_paid_checks() {
  check_haiku_answers_in_openwebui
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

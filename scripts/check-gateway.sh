#!/usr/bin/env bash
# Checks the Brána (LiteLLM) the way Chat calls it, with only LiteLLM and Postgres running: budgets and
# the Czech message for every refused request. Starts those two services if they are not up (CI), sets
# up Chat's key and the staff budget like bootstrap.sh, and deletes the data it creates. Free: every
# request is refused before it could reach a provider, and CI's provider keys are made up anyway.
set -euo pipefail
. "$(dirname "$0")/bootstrap.sh"
. "$(dirname "$0")/test-lib.sh"

# Chat calls LiteLLM with its own key and the signed-in person's e-mail in this header
# (litellm/config.yaml: user_header_mappings), so LiteLLM charges and budgets that person.
as_chat_user() {
  local email=$1 path=$2 body=$3
  curl -sS -X POST "$LITELLM_URL$path" \
    --config <(printf 'header = "Authorization: Bearer %s"\nheader = "X-OpenWebUI-User-Email: %s"\n' "$OPENWEBUI_LITELLM_KEY" "$email") \
    -H 'Content-Type: application/json' --data-binary @<(printf '%s' "$body") 2>/dev/null || true
}

# A staff member whose spend is already over the default budget. The spend is checked before any
# request: without it a request would reach the provider.
overspent_staff_member() {
  local email=$1
  create_temporary_customer "$email" 6
  [ "$(customer_spend "$email")" = "6.0" ] || fail "temporary customer $email has no recorded spend; refusing a call that could be paid"
}

check_personal_budget() {
  local email other
  email=$(unique_smoke_email)
  overspent_staff_member "$email"
  assert_personal_budget_message "$(as_chat_user "$email" /v1/chat/completions "$SMALL_CHAT")" "$email"
  pass "a staff member over budget gets a Czech message with the amount and the reset day"
  # A custom "user" parameter (allowed in Chat's settings) must not move spend to another identity.
  other=$(unique_smoke_email)
  on_exit_cleanup delete_litellm_customer "$other" # exists only if the dodge ever worked
  assert_personal_budget_message "$(as_chat_user "$email" /v1/chat/completions "$(jq -c --arg u "$other" '.user = $u' <<<"$SMALL_CHAT")")" "$email"
  pass "the budget cannot be dodged with a custom 'user' parameter"
  assert_personal_budget_message "$(as_chat_user "$email" /v1/images/generations "$(jq -c --arg m "$IMAGE_MODEL" '.model = $m' <<<"$SMALL_IMAGE")")" "$email"
  pass "a staff member over budget cannot generate images either"
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

main() {
  require_tools docker curl jq openssl
  load_env
  compose up -d --wait litellm
  ensure_openwebui_litellm_key
  ensure_staff_budget
  check_personal_budget
  check_school_budget_message_is_czech
  check_config_error_message_is_czech
}

main "$@"

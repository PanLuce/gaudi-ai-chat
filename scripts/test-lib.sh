# Helpers for the checks and demos only (smoke.sh, check-*.sh, demo-*.sh): test data, waiting, tags.
# Source it instead of lib.sh, which it sources first. Every helper that creates data deletes it on exit.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# A unique tag for data a check creates, so its cleanup (or a person) can always find it.
smoke_tag() { echo "smoke-$1-$(date +%s)-$RANDOM"; }

unique_smoke_email() { echo "$(smoke_tag user)@skolagaudi.cz"; }

# Runs the command until it succeeds: retry_until <tries> <seconds between> <command…>. Non-zero when it never does.
retry_until() {
  local tries=$1 delay=$2 attempt
  shift 2
  for attempt in $(seq 1 "$tries"); do
    "$@" && return 0
    [ "$attempt" = "$tries" ] || sleep "$delay"
  done
  return 1
}

# What LiteLLM has charged to a person's e-mail, empty when it knows no such person.
customer_spend() {
  litellm_admin GET "/customer/info?end_user_id=$1" 2>/dev/null | jq -r '.spend // empty' || true
}

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

# Creates a regular Chat account (role user), deleted on exit: create_staff_account <e-mail> <password> [name].
# Call it directly, never inside $(...): a subshell would lose the cleanup registration.
create_staff_account() {
  local email=$1 password=$2 name=${3:-$1} user_id
  user_id=$(openwebui_admin POST /api/v1/auths/add \
    "$(jq -n --arg e "$email" --arg p "$password" --arg n "$name" '{name: $n, email: $e, password: $p, role: "user"}')" \
    | jq -er .id) || fail "could not create the staff account $email"
  on_exit_cleanup openwebui_admin DELETE "/api/v1/users/$user_id"
}

# A staff account for a check, signed in: sets TEMP_USER_TOKEN. Call it directly, never inside $(...).
create_temporary_staff_user() {
  local email=$1 password
  password=$(openssl rand -hex 16)
  create_staff_account "$email" "$password"
  TEMP_USER_TOKEN=$(api_request "" POST "$OPENWEBUI_URL/api/v1/auths/signin" \
    "$(jq -n --arg e "$email" --arg p "$password" '{email: $e, password: $p}')" | jq -er .token) \
    || fail "could not sign in temporary user $email"
}

wait_until_demo_is_done() {
  read -r -p "Press Enter when done (the account is then deleted)… " _
  info "deleting the demo account"
}

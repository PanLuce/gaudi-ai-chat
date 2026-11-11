#!/usr/bin/env bash
# Manual demo: a staff member who is over budget cannot chat or generate images.
# Creates a temporary account, waits while you try it in the browser, then deletes everything
# (also on Ctrl+C). The same scenario runs automatically in scripts/smoke.sh.
# Nothing reaches a provider: LiteLLM refuses the requests before calling Anthropic or Google.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

readonly DEMO_SPEND_USD=6 # above the $STAFF_BUDGET_USD budget

create_demo_account() {
  local email=$1 password=$2 user_id
  user_id=$(openwebui_admin POST /api/v1/auths/add \
    "$(jq -n --arg e "$email" --arg p "$password" '{name: "Demo přes rozpočet", email: $e, password: $p, role: "user"}')" \
    | jq -er .id) || fail "could not create the demo account"
  on_exit_cleanup openwebui_admin DELETE "/api/v1/users/$user_id"
  create_temporary_customer "$email" "$DEMO_SPEND_USD"
}

print_instructions() {
  cat <<EOF

Demo account (spend \$$DEMO_SPEND_USD, budget \$$STAFF_BUDGET_USD):
  URL:      $OPENWEBUI_URL   (use a private window)
  e-mail:   $1
  password: $2

Try:
  1. a text message        → error "ExceededBudget … Spend=$DEMO_SPEND_USD.0, Budget=$STAFF_BUDGET_USD.0"
  2. the image button      → error, no image
  3. LiteLLM UI → Logs     → status failure, spend \$0

EOF
}

main() {
  require_tools docker curl jq openssl
  load_env
  local email password
  email="smoke-demo-$(date +%s)@skolagaudi.cz"
  password=$(openssl rand -hex 8)
  create_demo_account "$email" "$password"
  print_instructions "$email" "$password"
  read -r -p "Press Enter when done (the account is then deleted)… " _
  info "deleting the demo account"
}

main "$@"

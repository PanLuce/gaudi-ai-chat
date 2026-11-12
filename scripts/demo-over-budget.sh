#!/usr/bin/env bash
# Manual demo: a staff member who is over budget cannot chat or generate images.
# Creates a temporary account, waits while you try it in the browser, then deletes everything
# (also on Ctrl+C). The same scenario runs automatically in scripts/smoke.sh.
# Nothing reaches a provider: LiteLLM refuses the requests before calling Anthropic or Google.
set -euo pipefail
. "$(dirname "$0")/test-lib.sh"

readonly DEMO_SPEND_USD=6 # above the $STAFF_BUDGET_USD budget

print_instructions() {
  cat <<EOF

Demo account (spend \$$DEMO_SPEND_USD, budget \$$STAFF_BUDGET_USD):
  URL:      $OPENWEBUI_URL   (use a private window)
  e-mail:   $1
  password: $2

Try:
  1. a text message        → Czech error "Tvůj rozpočet na AI chat je vyčerpaný. … (kód: rozpocet)"
  2. the image button      → error, no image
  3. LiteLLM UI → Logs     → status failure, spend \$0

EOF
}

main() {
  require_tools docker curl jq openssl
  load_env
  local email password
  email="$(smoke_tag demo)@skolagaudi.cz"
  password=$(openssl rand -hex 8)
  create_staff_account "$email" "$password" "Demo přes rozpočet"
  create_temporary_customer "$email" "$DEMO_SPEND_USD"
  print_instructions "$email" "$password"
  wait_until_demo_is_done
}

main "$@"

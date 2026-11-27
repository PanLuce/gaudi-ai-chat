#!/usr/bin/env bash
# Checks the contract between bootstrap.sh and Chat (Open WebUI): bootstrap finds every admin API it
# calls, then Chat offers the Claude models through the Brána and knows its public address. In CI the
# database is empty, as on a new server. Runs Vchod, Chat, Brána and Databáze, not the Terminál: its
# image is 7 GB and bootstrap only stores its address. A Chat version that renames an API fails here,
# as v0.13.5 did (#32). Free: nothing reaches a provider.
set -euo pipefail
. "$(dirname "$0")/bootstrap.sh"
. "$(dirname "$0")/test-lib.sh"

check_openwebui_offers_claude_models() {
  local offered
  offered=$(openwebui_admin GET /api/models | jq -r '.data[].id' | grep '^claude-' | sort | xargs)
  [ "$offered" = "$EXPECTED_TEXT_MODELS" ] || fail "Open WebUI offers [$offered], expected [$EXPECTED_TEXT_MODELS]"
  pass "Open WebUI offers $EXPECTED_TEXT_MODELS"
}

# Links in e-mails and OAuth redirects are built from this address.
check_openwebui_knows_its_public_address() {
  local configured
  configured=$(openwebui_admin GET /api/v1/auths/admin/config | jq -r '.WEBUI_URL')
  [ "$configured" = "$OPENWEBUI_URL" ] || fail "Open WebUI thinks its address is $configured, expected $OPENWEBUI_URL"
  pass "Open WebUI knows its public address $OPENWEBUI_URL"
}

main() {
  require_tools docker curl jq openssl
  load_env
  compose up -d --wait litellm
  compose up -d --wait --no-deps open-webui caddy
  configure_stack
  pass "bootstrap sets up Chat through every admin API it calls"
  check_openwebui_offers_claude_models
  check_openwebui_knows_its_public_address
}

main "$@"

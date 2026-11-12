#!/usr/bin/env bash
# Manual demo: see Open WebUI the way a regular staff member does.
# Creates a temporary account, waits while you try it in the browser, then deletes it
# (also on Ctrl+C). Free unless you send a chat message or ask for an image.
set -euo pipefail
. "$(dirname "$0")/test-lib.sh"

print_instructions() {
  cat <<INSTRUCTIONS

Demo staff account:
  URL:      $OPENWEBUI_URL   (use a private window)
  e-mail:   $1
  password: $2

Look, without sending anything:
  1. the model picker      → the models the admin made visible to everyone
  2. the input field       → no terminal (unless the admin granted it)
  3. the image button      → present

INSTRUCTIONS
}

main() {
  require_tools docker curl jq openssl
  load_env
  local email password
  email="$(smoke_tag demo-staff)@skolagaudi.cz"
  password=$(openssl rand -hex 8)
  create_staff_account "$email" "$password" "Demo zaměstnanec"
  print_instructions "$email" "$password"
  wait_until_demo_is_done
}

main "$@"

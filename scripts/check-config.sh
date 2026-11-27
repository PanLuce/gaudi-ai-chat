#!/usr/bin/env bash
# Checks the stack's configuration without starting anything: what docker-compose.yml publishes and
# which models litellm/config.yaml offers. Needs only the docker compose CLI and a .env (CI makes one with
# scripts/ci-env.sh). Free, and fast enough to run on every pull request.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

# Only Caddy (Vchod) is for people; LiteLLM (Brána) is published for the admin, on 127.0.0.1 only.
check_only_caddy_is_published() {
  local exposed
  exposed=$(compose config --format json | jq -r '[.services | to_entries[] | .key as $s | .value.ports[]?
      | select(.published != null) | select($s != "caddy" and ($s != "litellm" or .host_ip != "127.0.0.1"))
      | "\($s) \(.host_ip // "0.0.0.0"):\(.published)"] | join(", ")') \
    || fail "could not read docker-compose.yml with .env (CI makes one with scripts/ci-env.sh)"
  [ -z "$exposed" ] || fail "published past Caddy: $exposed"
  pass "docker-compose.yml publishes only Caddy; LiteLLM listens on 127.0.0.1 only"
}

# The text models people pick in Chat; the image model is checked by its own steps.
check_litellm_offers_claude_models() {
  local offered
  offered=$(grep -oE '^ *- model_name: claude-[a-z]+$' "$REPO_ROOT/litellm/config.yaml" | awk '{print $3}' | sort | xargs)
  [ "$offered" = "$EXPECTED_TEXT_MODELS" ] || fail "litellm/config.yaml offers [$offered], expected [$EXPECTED_TEXT_MODELS]"
  pass "litellm/config.yaml offers $EXPECTED_TEXT_MODELS"
}

main() {
  require_tools docker jq
  check_only_caddy_is_published
  check_litellm_offers_claude_models
}

main "$@"

#!/usr/bin/env bash
# Runs litellm/test_czech_errors.py inside the LiteLLM image that docker-compose.yml pins, so the Czech
# messages are tested against the exact LiteLLM version the server runs (and Dependabot bumps).
# Needs Docker and a .env (CI makes one with scripts/ci-env.sh); starts no service. Free.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

main() {
  require_tools docker jq
  local image
  image=$(compose config --format json | jq -er '.services.litellm.image') || fail "no litellm image in docker-compose.yml"
  docker run --rm --network none --entrypoint python \
    -e PYTHONDONTWRITEBYTECODE=1 -e PYTHONWARNINGS=ignore -e LITELLM_LOCAL_MODEL_COST_MAP=True \
    -v "$REPO_ROOT/litellm:/tests:ro" -w /tests "$image" -m unittest -v test_czech_errors \
    || fail "Czech error messages ($image): see the failing test above"
  pass "every error a person can see has a Czech message ($image)"
}

main "$@"

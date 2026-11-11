# openwebui-local

Open WebUI + LiteLLM + Postgres stack for Škola Gaudi staff. See README.md for how to run it.

## Rules
- Build only what production will run. No stand-ins (mock models, local IdP, self-signed CA); only `.env` values differ between local and production.
- Documentation: ADRs yes (`docs/adr/`, only for hard-to-reverse, surprising trade-offs), no glossary.
- Every provider call goes through LiteLLM; Open WebUI never talks to a provider directly.
- The Anthropic key must be created inside the `openwebui` workspace in console.anthropic.com: keys outside a workspace are rejected (LiteLLM sends no `anthropic-workspace-id`), and the workspace carries the provider-side spend limit.
- Open WebUI stores its config in its database after the first start, so env vars only seed a fresh database. Change live settings through `scripts/bootstrap.sh` (admin API), not by editing `docker-compose.yml` alone.

## Running things
- Verify with `scripts/smoke.sh` after every change; add a failing check first, then the change.
- Smoke checks that create data tag it `smoke-<timestamp>` and delete it in an EXIT trap.
- Scripts read `.env`, which the Claude Code sandbox may not read, and `docker` needs the Docker socket: run scripts and docker commands outside the sandbox.
- Never print or commit secrets; `.env` is git-ignored.

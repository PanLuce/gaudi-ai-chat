# gaudi-ai-chat

Caddy + Open WebUI + LiteLLM + Postgres + open-terminal stack for Škola Gaudi staff (Vchod, Chat, Brána, Databáze, Terminál in the docs). See README.md for how to run it.

## Rules
- The repo, the compose project (`name:` in `docker-compose.yml`) and the server folder (`~/gaudi-ai-chat`) are all named `gaudi-ai-chat` (renamed from `openwebui-local` while there was no real data). The compose name prefixes the Docker volumes: renaming it again starts an empty database next to the old one.
- Build only what production will run. No stand-ins (mock models, local IdP, self-signed CA); only `.env` values differ between local and production.
- Documentation: ADRs yes (`docs/adr/`, only for hard-to-reverse, surprising trade-offs), no glossary.
- Every provider call goes through LiteLLM; Open WebUI never talks to a provider directly.
- The Anthropic key must be created inside the `openwebui` workspace in console.anthropic.com: keys outside a workspace are rejected (LiteLLM sends no `anthropic-workspace-id`), and the workspace carries the provider-side spend limit.
- Open WebUI stores its config in its database after the first start, so env vars only seed a fresh database. Change live settings through `scripts/bootstrap.sh` (admin API), not by editing `docker-compose.yml` alone.
- Access rules: a model's grants change only through `/api/v1/models/model/access/update` (`/model/update` ignores them); a terminal's live in its connection's `config.access_grants` (`/api/v1/configs/terminal_servers`), where no grants means admins only. Grant `user:*` = all signed-in people; `anyone:*` = public without login — never use it.

## Running things
- Verify with `scripts/smoke.sh` after every change; add a failing check first, then the change.
- Smoke checks that create data tag it `smoke-<timestamp>` and delete it in an EXIT trap.
- Scripts read `.env`, which the Claude Code sandbox may not read, and `docker` needs the Docker socket: run scripts and docker commands outside the sandbox.
- `scripts/check-docs.sh` needs the running stack (its link checks call localhost). Without it, run the offline checks alone: copy the script without its last line (`main "$@"`), then call only `check_overview_*` and `check_guide_*`.
- Never print or commit secrets; `.env` is git-ignored.
- Claude creates feature branches itself (`git switch -c <name>`, run outside the sandbox) — no manual branch step for the user.

#!/usr/bin/env bash
# Checks the explanatory pages in docs/: every link answers, they use one vocabulary,
# every script they mention exists, and nothing in them looks like a secret.
# Local links (localhost) need the running stack. Free.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

readonly PAGES="prehled.html nasazeni.html"
# One word for each part, the same on every page and in the README.
readonly VOCABULARY="Vchod Chat Brána Databáze Terminál Poskytovatelé"
# Exists only after deployment.
readonly NOT_YET_DEPLOYED="ai.skolagaudi.cz"
# Private: anonymous requests get 404, so ask GitHub as the signed-in user.
readonly PRIVATE_REPO="github.com/PanLuce/openwebui-local"

check_page_exists() {
  [ -s "$REPO_ROOT/docs/$1" ] || fail "docs/$1 is missing"
}

check_vocabulary() {
  local word
  for word in $VOCABULARY; do
    grep -q "$word" "$REPO_ROOT/docs/$1" || fail "docs/$1 does not use the name '$word'"
  done
}

# 2xx/3xx answers; 401/403/429 means the site blocks robots, which is only a warning.
check_link() {
  local url=$1 page=$2 status
  case "$url" in
    *"$NOT_YET_DEPLOYED"*) info "$page: $url exists after deployment, skipped"; return ;;
    *"$PRIVATE_REPO"*) gh repo view "${PRIVATE_REPO#github.com/}" >/dev/null 2>&1 || fail "$page: $url is not reachable with gh"; return ;;
  esac
  status=$(curl -s -o /dev/null -L --max-time 20 -A "Mozilla/5.0 (check-docs)" -w '%{http_code}' "$url" || true)
  case "$status" in
    2??|3??) ;;
    401|403|429) info "$page: $url answers $status (blocks robots), check it by hand" ;;
    *) fail "$page: $url answers ${status:-nothing}" ;;
  esac
}

check_links() {
  local url
  for url in $(grep -oE 'https?://[^"'"'"' <>)`]+' "$REPO_ROOT/docs/$1" | sed 's/[.,;:]$//' | sort -u); do
    check_link "$url" "$1"
  done
}

check_mentioned_scripts_exist() {
  local script
  for script in $(grep -oE 'scripts/[a-z-]+\.sh' "$REPO_ROOT/docs/$1" | sort -u); do
    [ -f "$REPO_ROOT/$script" ] || fail "docs/$1 mentions $script, which does not exist"
  done
}

check_no_secrets() {
  ! grep -nE 'sk-[A-Za-z0-9_-]{16,}|GOCSPX-[A-Za-z0-9_-]+|[0-9a-f]{32,}' "$REPO_ROOT/docs/$1" >/dev/null \
    || fail "docs/$1 contains something that looks like a secret"
}

# Runs the guide's own data script in node and checks the prompt of every step that is ready.
check_guide_prompts() {
  node - "$REPO_ROOT/docs/nasazeni.html" <<'JS' || fail "docs/nasazeni.html: a step has no complete prompt"
const fs = require("fs"), vm = require("vm");
const html = fs.readFileSync(process.argv[2], "utf8");
const data = html.match(/<script id="guide-data">([\s\S]*?)<\/script>/);
if (!data) { console.error("✗ no <script id=\"guide-data\"> with the steps"); process.exit(1); }
const context = {};
vm.runInNewContext(data[1] + "\nthis.STEPS = STEPS; this.promptFor = promptFor;", context);
let failed = false;
context.STEPS.forEach((step, index) => {
  if (step.todo) return;
  const prompt = context.promptFor(step, index);
  const required = [step.title, step.see, "gaudi-ai", "Nikdy nevypisuj"].concat(step.command ? [step.command] : []);
  required.filter((part) => !prompt.includes(part))
    .forEach((part) => { failed = true; console.error(`✗ step ${index + 1} (${step.title}): prompt lacks "${part.slice(0, 40)}"`); });
});
process.exit(failed ? 1 : 0);
JS
  pass "docs/nasazeni.html: every ready step exports a complete prompt"
}

main() {
  require_tools curl grep node
  local page
  for page in $PAGES; do
    check_page_exists "$page"
    check_vocabulary "$page"
    check_mentioned_scripts_exist "$page"
    check_no_secrets "$page"
    check_links "$page"
    pass "docs/$page: links answer, one vocabulary, no secrets"
  done
  check_guide_prompts
}

main "$@"

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
// A command is copied as it is, so it must not hold anything the reader has to replace inside it.
context.STEPS.forEach((step, index) => {
  if (step.command && /203\.0\.113\.|<[^>]*>/.test(step.command)) {
    failed = true; console.error(`✗ step ${index + 1} (${step.title}): the command holds a placeholder to replace`);
  }
});
// Secrets never reach a screen or a transcript: no command prints a new one, and every step that
// handles .env contents is done by the person, with a prompt that tells Claude not to run it.
context.STEPS.forEach((step, index) => {
  if (!step.command) return;
  if (/^\s*(echo [^|>]*openssl rand|openssl rand)/m.test(step.command)) {
    failed = true; console.error(`✗ step ${index + 1} (${step.title}): the command prints a generated secret`);
  }
  if (/nano \.env|cat [^\n]*\.env|scp [^\n]*\.env/.test(step.command)
      && !(step.manual && context.promptFor(step, index).includes("Nespouštěj"))) {
    failed = true; console.error(`✗ step ${index + 1} (${step.title}): handles .env but is not a manual step`);
  }
});
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

check_guide_phases() {
  node - "$REPO_ROOT/docs/nasazeni.html" <<'JS' || fail "docs/nasazeni.html: a phase button does not say which steps it holds"
const fs = require("fs"), vm = require("vm");
const html = fs.readFileSync(process.argv[2], "utf8");
const data = html.match(/<script id="guide-data">([\s\S]*?)<\/script>/)[1];
const context = {};
vm.runInNewContext(data + "\nthis.STEPS = STEPS; this.phaseLabel = typeof phaseLabel === 'function' ? phaseLabel : null;", context);
if (!context.phaseLabel) { console.error("✗ no phaseLabel(phase) in guide-data"); process.exit(1); }
// A phase button jumps to the phase's first step, so its label must show the step numbers it covers.
let failed = false, expectedFirst = 1;
const phases = [...new Set(context.STEPS.map((step) => step.phase))];
phases.forEach((phase) => {
  const numbers = context.STEPS.map((step, index) => step.phase === phase ? index + 1 : null).filter(Boolean);
  const first = numbers[0], last = numbers[numbers.length - 1];
  if (first !== expectedFirst || last - first + 1 !== numbers.length) {
    failed = true; console.error(`✗ phase ${phase}: steps ${numbers.join(", ")} are not one block after step ${expectedFirst - 1}`);
  }
  const wanted = first === last ? `${phase} · ${first}` : `${phase} · ${first}–${last}`;
  if (context.phaseLabel(phase) !== wanted) {
    failed = true; console.error(`✗ phase ${phase}: label "${context.phaseLabel(phase)}", wanted "${wanted}"`);
  }
  expectedFirst = last + 1;
});
process.exit(failed ? 1 : 0);
JS
  pass "docs/nasazeni.html: every phase button names its steps"
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
  check_guide_phases
}

main "$@"

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
readonly PRIVATE_REPO="github.com/PanLuce/gaudi-ai-chat"
# The name before the rename: the repo, the compose project and the server folder all dropped it.
readonly OLD_NAME="openwebui-local"

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

# A renamed repo still redirects, so a stale name would pass the link check unnoticed.
check_repo_name() {
  local stale
  stale=$(grep -oE 'PanLuce/[A-Za-z0-9._-]+' "$REPO_ROOT/docs/$1" | sed 's/\.git$//' | sort -u | grep -vx "${PRIVATE_REPO#github.com/}" || true)
  [ -z "$stale" ] || fail "docs/$1 names the repo as $stale, not ${PRIVATE_REPO#github.com/}"
  ! grep -q "$OLD_NAME" "$REPO_ROOT/docs/$1" || fail "docs/$1 still uses the old name $OLD_NAME"
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
# Every guide check starts from the same data: the <script id="guide-data"> of docs/nasazeni.html,
# run in a sandbox. The check's JS gets `guide` with STEPS and the helpers the page defines (null if missing).
readonly GUIDE_LOADER='const fs = require("fs"), vm = require("vm");
const html = fs.readFileSync(process.argv[2], "utf8");
const data = html.match(/<script id="guide-data">([\s\S]*?)<\/script>/);
if (!data) { console.error("✗ no <script id=\"guide-data\"> with the steps"); process.exit(1); }
const guide = {};
vm.runInNewContext(data[1] + `
this.STEPS = typeof STEPS === "undefined" ? null : STEPS;
this.promptFor = typeof promptFor === "function" ? promptFor : null;
this.phaseLabel = typeof phaseLabel === "function" ? phaseLabel : null;
this.phaseSteps = typeof phaseSteps === "function" ? phaseSteps : null;`, guide);
if (!guide.STEPS) { console.error("✗ guide-data defines no STEPS"); process.exit(1); }'

# Reads the check's JS from stdin and runs it after the loader; fails with $1 when it exits non-zero.
run_guide_check() {
  { printf '%s\n' "$GUIDE_LOADER"; cat; } | node - "$REPO_ROOT/docs/nasazeni.html" || fail "$1"
}

check_guide_prompts() {
  run_guide_check "docs/nasazeni.html: a step has no complete prompt" <<'JS'
let failed = false;
// A command is copied as it is, so it must not hold anything the reader has to replace inside it.
guide.STEPS.forEach((step, index) => {
  if (step.command && /203\.0\.113\.|<[^>]*>/.test(step.command)) {
    failed = true; console.error(`✗ step ${index + 1} (${step.title}): the command holds a placeholder to replace`);
  }
});
// Every line of a command is complete: a quote left open (e.g. a "\\n" the page turned into a real line break)
// splits one shell command over two lines of the copied text.
guide.STEPS.forEach((step, index) => {
  (step.command || "").split("\n").forEach((line) => {
    if ((line.match(/'/g) || []).length % 2) {
      failed = true; console.error(`✗ step ${index + 1} (${step.title}): a quote is left open in: ${line.slice(0, 60)}`);
    }
  });
});
// Secrets never reach a screen or a transcript: no command prints a new one, and every step that
// handles .env contents is done by the person, with a prompt that tells Claude not to run it.
guide.STEPS.forEach((step, index) => {
  if (!step.command) return;
  if (/^\s*(echo [^|>]*openssl rand|openssl rand)/m.test(step.command)) {
    failed = true; console.error(`✗ step ${index + 1} (${step.title}): the command prints a generated secret`);
  }
  if (/nano \.env|(cat|grep|scp) [^\n]*\.env/.test(step.command)
      && !(step.manual && guide.promptFor(step, index).includes("Nespouštěj"))) {
    failed = true; console.error(`✗ step ${index + 1} (${step.title}): handles .env but is not a manual step`);
  }
});
guide.STEPS.forEach((step, index) => {
  const prompt = guide.promptFor(step, index);
  const required = [step.title, step.see, "gaudi-ai", "Nikdy nevypisuj"].concat(step.command ? [step.command] : []);
  required.filter((part) => !prompt.includes(part))
    .forEach((part) => { failed = true; console.error(`✗ step ${index + 1} (${step.title}): prompt lacks "${part.slice(0, 40)}"`); });
});
process.exit(failed ? 1 : 0);
JS
  pass "docs/nasazeni.html: every ready step exports a complete prompt"
}

check_guide_phases() {
  run_guide_check "docs/nasazeni.html: a phase button does not say which steps it holds" <<'JS'
if (!guide.phaseLabel) { console.error("✗ no phaseLabel(phase) in guide-data"); process.exit(1); }
// A phase button jumps to the phase's first step, so its label must show the step numbers it covers.
let failed = false, expectedFirst = 1;
const phases = [...new Set(guide.STEPS.map((step) => step.phase))];
phases.forEach((phase) => {
  const numbers = guide.STEPS.map((step, index) => step.phase === phase ? index + 1 : null).filter(Boolean);
  const first = numbers[0], last = numbers[numbers.length - 1];
  if (first !== expectedFirst || last - first + 1 !== numbers.length) {
    failed = true; console.error(`✗ phase ${phase}: steps ${numbers.join(", ")} are not one block after step ${expectedFirst - 1}`);
  }
  const wanted = first === last ? `${phase} · ${first}` : `${phase} · ${first}–${last}`;
  if (guide.phaseLabel(phase) !== wanted) {
    failed = true; console.error(`✗ phase ${phase}: label "${guide.phaseLabel(phase)}", wanted "${wanted}"`);
  }
  expectedFirst = last + 1;
});
process.exit(failed ? 1 : 0);
JS
  pass "docs/nasazeni.html: every phase button names its steps"
}

check_guide_phase_steps() {
  run_guide_check "docs/nasazeni.html: a phase does not list all its steps" <<'JS'
if (!guide.phaseSteps) { console.error("✗ no phaseSteps(phase) in guide-data"); process.exit(1); }
// The row under the phase buttons must offer every step of the current phase, by number and a short name.
let failed = false;
guide.STEPS.forEach((step, index) => {
  if (!step.short || step.short.length > 24) {
    failed = true; console.error(`✗ step ${index + 1} (${step.title}): short name missing or longer than 24 characters`);
  }
});
[...new Set(guide.STEPS.map((step) => step.phase))].forEach((phase) => {
  const wanted = guide.STEPS.map((step, index) => step.phase === phase ? `${index}|${index + 1} ${step.short}` : null).filter(Boolean).join(",");
  const got = guide.phaseSteps(phase).map((item) => `${item.index}|${item.label}`).join(",");
  if (got !== wanted) { failed = true; console.error(`✗ phase ${phase}: row "${got}", wanted "${wanted}"`); }
});
process.exit(failed ? 1 : 0);
JS
  pass "docs/nasazeni.html: every phase lists all its steps"
}

# The overview's data (<script id="overview-data"> of docs/prehled.html), run in a sandbox like the guide's.
readonly OVERVIEW_LOADER='const fs = require("fs"), vm = require("vm");
const html = fs.readFileSync(process.argv[2], "utf8");
const data = html.match(/<script id="overview-data">([\s\S]*?)<\/script>/);
if (!data) { console.error("✗ no <script id=\"overview-data\"> with the parts"); process.exit(1); }
const overview = {};
vm.runInNewContext(data[1] + `
this.PARTS = typeof PARTS === "undefined" ? null : PARTS;
this.TRIP = typeof TRIP === "undefined" ? null : TRIP;
this.ICONS = typeof ICONS === "undefined" ? {} : ICONS;`, overview);
if (!overview.PARTS || !overview.TRIP) { console.error("✗ overview-data defines no PARTS or no TRIP"); process.exit(1); }'

# Reads the check's JS from stdin and runs it after the overview loader; fails with $1 when it exits non-zero.
run_overview_check() {
  { printf '%s\n' "$OVERVIEW_LOADER"; cat; } | node - "$REPO_ROOT/docs/prehled.html" || fail "$1"
}

check_overview_trip() {
  run_overview_check "docs/prehled.html: the query trip does not follow the picture" <<'JS'
let failed = false;
const report = (message) => { failed = true; console.error(`✗ ${message}`); };
const ids = new Set(overview.PARTS.map((part) => part.id));
// The question starts with the person before the picture, then travels along the path.
const pathOrder = overview.PARTS.filter((part) => part.place === "start" || part.place === "path").map((part) => part.id);
let lastPathIndex = -1;
overview.TRIP.forEach((step, index) => {
  const label = `trip step ${index + 1}`;
  step.parts.filter((id) => !ids.has(id)).forEach((id) => report(`${label}: no part "${id}"`));
  // The caption sits under the picture on one line on a desktop.
  if (step.text.length > 80) report(`${label}: text has ${step.text.length} characters, at most 80`);
  // One concrete trip: every step follows the same person and their question.
  if (!/Frant/.test(step.text)) report(`${label}: does not follow Franta's question ("${step.text}")`);
  // The question travels along the picture; a step lights up the next part on the path (backstage parts may join).
  const onPath = step.parts.map((id) => pathOrder.indexOf(id)).filter((position) => position >= 0);
  const furthest = Math.max(...onPath);
  if (onPath.length === 0) report(`${label}: lights up no part on the path`);
  else if (furthest !== lastPathIndex + 1) report(`${label}: jumps to "${pathOrder[furthest]}", next on the path is "${pathOrder[lastPathIndex + 1]}"`);
  lastPathIndex = Math.max(lastPathIndex, furthest);
});
if (lastPathIndex !== pathOrder.length - 1) report("the trip does not reach the last part on the path");
// A concrete example quotes both ends: Franta's question in the first step, the answer in the last.
[0, overview.TRIP.length - 1].filter((index) => !/„[^“]+“/.test(overview.TRIP[index].text))
  .forEach((index) => report(`trip step ${index + 1}: quotes no concrete question or answer („…“)`));
// Every part shows a picture of where it happens, on the map and in the trip bar.
overview.PARTS.filter((part) => !/<svg[\s\S]*<\/svg>/.test(overview.ICONS[part.id] || ""))
  .forEach((part) => report(`part "${part.id}" has no icon in ICONS`));
process.exit(failed ? 1 : 0);
JS
  pass "docs/prehled.html: the query trip follows Franta's question across the picture, one line and one icon per step"
}

check_overview_counts_parts() {
  run_overview_check "docs/prehled.html: the person who asks is counted as a part of the system" <<'JS'
let failed = false;
const report = (message) => { failed = true; console.error(`✗ ${message}`); };
// The person who asks stands before the picture, so a newcomer does not take them for a part (or for the Chat window).
const start = overview.PARTS.filter((part) => part.place === "start");
if (start.length !== 1 || start[0].kind !== "person") report(`expected one person at place "start", found ${start.length}`);
const systemParts = overview.PARTS.filter((part) => part.place !== "start").length;
const NUMBERS = { Čtyři: 4, Pět: 5, Šest: 6, Sedm: 7 };
const lead = fs.readFileSync(process.argv[2], "utf8").match(/<p class="lead">(\S+) částí/);
if (!lead || NUMBERS[lead[1]] !== systemParts) report(`the lead says "${lead && lead[1]}" parts, the system has ${systemParts}`);
process.exit(failed ? 1 : 0);
JS
  pass "docs/prehled.html: the person who asks stands before the picture; the lead counts only the system's parts"
}

check_guide_offsite_copy() {
  run_guide_check "docs/nasazeni.html: the nightly backup does not reach Google Drive" <<'JS'
// A backup that stays on the server dies with it: the nightly run must also copy it off the server.
const nightly = guide.STEPS.find((step) => step.title === "Zapni noční zálohu");
const offsite = guide.STEPS.find((step) => step.title === "Zálohy mimo server (Google Drive)");
let failed = false;
if (!nightly || !/scripts\/backup\.sh && scripts\/offsite\.sh upload/.test(nightly.command || "")) {
  failed = true; console.error("✗ the nightly crontab line does not run scripts/offsite.sh upload after the backup");
}
if (!offsite || !/scripts\/offsite\.sh upload/.test(offsite.command || "")) {
  failed = true; console.error("✗ the step Zálohy mimo server is not ready or does not try an upload");
}
process.exit(failed ? 1 : 0);
JS
  pass "docs/nasazeni.html: the nightly backup is copied to Google Drive"
}

# Sign-up is closed (WEBUI_ADMIN_EMAIL) until Google login (#3) lands in docker-compose.yml.
check_guide_matches_the_stack() {
  local signup_open=false
  grep -q ENABLE_OAUTH_SIGNUP "$REPO_ROOT/docker-compose.yml" && signup_open=true
  SIGNUP_OPEN=$signup_open run_guide_check "docs/nasazeni.html: a step does not match how the stack works" <<'JS'
let failed = false;
const at = (title) => guide.STEPS.findIndex((step) => step.title === title);
const text = (step) => [step.why, step.where, step.see].join(" ");
if (process.env.SIGNUP_OPEN !== "true") {
  guide.STEPS.forEach((step, index) => {
    if (/zaregistr/i.test(text(step))) {
      failed = true; console.error(`✗ step ${index + 1} (${step.title}): sends people to sign up, but sign-up is closed`);
    }
  });
}
// The copy in the password manager must hold everything a restore on a new server needs.
const saved = guide.STEPS[at("Ulož .env do správce hesel")], drive = at("Zálohy mimo server (Google Drive)");
if (!saved || drive < 0 || at("Ulož .env do správce hesel") < drive || !/drive-backup\.json/.test(text(saved))) {
  failed = true; console.error("✗ the .env copy in the password manager is made before the Drive settings, or without the Drive key");
}
// Each provider has its own spending cap, set by the admin, behind the budgets in the Gateway.
if (!guide.STEPS.some((step) => /Monthly spend cap/.test(text(step)))) {
  failed = true; console.error("✗ no step sets the Gemini spend cap in Google AI Studio");
}
process.exit(failed ? 1 : 0);
JS
  pass "docs/nasazeni.html: the guide matches closed sign-up, the backup keys and the provider caps"
}

# On a new server the old .env holds keys that exist only in the old databases, so bootstrap can run only
# after the restore has brought them back.
check_readme_restore_order() {
  local recipe restore_line bootstrap_line
  recipe=$(awk '/^### Obnova z Google Drive/{on=1} on && /^```sh/{code=1; next} code && /^```/{exit} code' "$REPO_ROOT/README.md")
  [ -n "$recipe" ] || fail "README.md has no ### Obnova z Google Drive with a sh block"
  restore_line=$(grep -n 'scripts/restore.sh' <<<"$recipe" | head -1 | cut -d: -f1)
  bootstrap_line=$(grep -n 'scripts/bootstrap.sh' <<<"$recipe" | head -1 | cut -d: -f1)
  [ -n "$restore_line" ] && [ -n "$bootstrap_line" ] && [ "$bootstrap_line" -gt "$restore_line" ] \
    || fail "README.md: the restore from Google Drive must run scripts/bootstrap.sh after scripts/restore.sh"
  pass "README.md: the restore from Google Drive runs bootstrap only after the databases are back"
}

# No check spends provider credit: a real answer and a real image are tried by hand in the guide.
check_no_paid_checks() {
  ! grep -n -- '--paid' "$REPO_ROOT/README.md" "$REPO_ROOT/docs/nasazeni.html" "$REPO_ROOT/scripts/smoke.sh" \
    || fail "a document or smoke.sh still offers paid checks (--paid)"
  pass "no check spends provider credit"
}

main() {
  require_tools curl gh grep node
  local page
  for page in $PAGES; do
    check_page_exists "$page"
    check_vocabulary "$page"
    check_mentioned_scripts_exist "$page"
    check_no_secrets "$page"
    check_repo_name "$page"
    check_links "$page"
    pass "docs/$page: links answer, one vocabulary, no secrets"
  done
  check_guide_prompts
  check_guide_phases
  check_guide_phase_steps
  check_overview_trip
  check_overview_counts_parts
  check_guide_offsite_copy
  check_guide_matches_the_stack
  check_readme_restore_order
  check_no_paid_checks
}

main "$@"

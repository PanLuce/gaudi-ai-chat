#!/usr/bin/env bash
# Checks that a backup brings back real data from all three places it covers:
# a chat (Open WebUI database), an uploaded file and its search index (Open WebUI volume) and a person's
# spend (LiteLLM database).
# NOT for a server people are using: restoring rolls both databases back to the moment of the backup.
# Free: nothing reaches a provider.
set -euo pipefail
. "$(dirname "$0")/test-lib.sh"

readonly TAG=$(smoke_tag backup)
readonly SPEND_EMAIL="$TAG@skolagaudi.cz"
readonly SPEND_USD=1.23
readonly FILE_CONTENT="$TAG file content"
readonly SEARCH_TEXT="Školní sad $TAG má třicet jabloní a dvě hrušně."

CHAT_ID=""
FILE_ID=""
SEARCH_FILE_ID=""
BACKUP_ROOT=""

create_chat() {
  CHAT_ID=$(openwebui_admin POST /api/v1/chats/new \
    "$(jq -cn --arg t "$TAG" '{chat: {title: $t, messages: [], history: {messages: {}}}}')" | jq -er .id) \
    || fail "could not create the test chat"
  on_exit_cleanup openwebui_admin DELETE "/api/v1/chats/$CHAT_ID"
}

# Multipart upload, so not through api_request; the key still travels in a curl config, not argv.
# upload_to_chat <file> <query string> prints the new file's id.
upload_to_chat() {
  curl -sS --fail-with-body -X POST "$OPENWEBUI_URL/api/v1/files/$2" \
    --config <(printf 'header = "Authorization: Bearer %s"\n' "$OPENWEBUI_ADMIN_API_KEY") \
    -F "file=@$1" | jq -er .id
}

upload_file() {
  local file="$BACKUP_ROOT/$TAG.txt"
  printf '%s' "$FILE_CONTENT" > "$file"
  FILE_ID=$(upload_to_chat "$file" "?process=false") || fail "could not upload the test file"
  on_exit_cleanup openwebui_admin DELETE "/api/v1/files/$FILE_ID"
}

# This file is processed: Open WebUI embeds it with its own local model (free) into the search index.
upload_searchable_file() {
  local file="$BACKUP_ROOT/$TAG-sad.txt"
  printf '%s\n' "$SEARCH_TEXT" > "$file"
  SEARCH_FILE_ID=$(upload_to_chat "$file" "") || fail "could not upload the searchable test file"
  # Deleting the file alone leaves its vectors in the index, so they go first (they need the file's hash).
  on_exit_cleanup delete_search_entries "$SEARCH_FILE_ID"
  on_exit_cleanup openwebui_admin DELETE "/api/v1/files/$SEARCH_FILE_ID"
  retry_until 30 2 file_search_finds_text || fail "file search never found the text of the uploaded file" # embedding runs in the background
}

delete_search_entries() {
  openwebui_admin POST /api/v1/retrieval/delete \
    "$(jq -cn --arg f "$1" '{collection_name: ("file-" + $f), file_id: $f}')" | jq -e '.status == true' >/dev/null
}

# Asks Open WebUI's search (the port people use through a chat), never the index file itself.
file_search_finds_text() {
  openwebui_admin POST /api/v1/retrieval/query/doc \
    "$(jq -cn --arg c "file-$SEARCH_FILE_ID" '{collection_name: $c, query: "Kolik jabloní má školní sad?", k: 3}')" 2>/dev/null \
    | jq -e --arg t "$TAG" '[.documents[]?[]?] | any(contains($t))' >/dev/null
}

assert_chat_runs_after_backup() {
  api_request "" GET "$OPENWEBUI_URL/health" >/dev/null 2>&1 || fail "Chat does not answer after backup.sh"
  pass "Chat answers again right after the backup"
}

# backup.sh's exit safety net, with a stand-in compose (no containers touched). A real Chat that
# never comes back cannot be produced on demand, so the stand-in refuses "up".
assert_failed_chat_restart_is_logged() {
  local output
  output=$(bash -c '. "$1/scripts/backup.sh"; compose() { [ "$1" != up ]; }; stop_chat' _ "$REPO_ROOT" 2>&1 || true)
  grep -q "cleanup failed: restart_chat_if_stopped" <<<"$output" \
    || fail "a backup that stops early does not report that Chat did not start again (got: $output)"
  pass "if Chat does not start again after a failed backup, the log says so"
}

assert_chat_is_started_once() {
  local calls starts
  calls=$(mktemp)
  COMPOSE_CALLS="$calls" bash -c '. "$1/scripts/backup.sh"; compose() { echo "$*" >> "$COMPOSE_CALLS"; }; stop_chat; start_chat' \
    _ "$REPO_ROOT" >/dev/null 2>&1
  starts=$(grep -c "^up " "$calls" || true)
  rm -f "$calls"
  [ "$starts" = 1 ] || fail "backup.sh starts Chat $starts times after a backup, expected once"
  pass "a successful backup starts Chat exactly once"
}

lose_the_data() {
  openwebui_admin DELETE "/api/v1/chats/$CHAT_ID" >/dev/null || fail "could not delete the test chat"
  openwebui_admin DELETE "/api/v1/files/$FILE_ID" >/dev/null || fail "could not delete the test file"
  openwebui_admin DELETE "/api/v1/files/$SEARCH_FILE_ID" >/dev/null || fail "could not delete the searchable test file"
  delete_litellm_customer "$SPEND_EMAIL"
  ! chat_exists || fail "the test chat is still there after deleting it"
}

chat_exists() { openwebui_admin GET "/api/v1/chats/$CHAT_ID" 2>/dev/null | jq -e --arg t "$TAG" '.title == $t' >/dev/null; }
file_content() { openwebui_admin GET "/api/v1/files/$FILE_ID/content" 2>/dev/null || true; }
recorded_spend() { customer_spend "$SPEND_EMAIL"; }

# A damaged backup must be refused before anything is deleted (the current data stays).
assert_damaged_backup_is_refused() {
  local good=$1 damaged_file=$2 damaged size
  damaged="$BACKUP_ROOT/damaged-$damaged_file"
  cp -R "$good" "$damaged"
  size=$(wc -c < "$good/$damaged_file")
  head -c $((size / 2)) "$good/$damaged_file" > "$damaged/$damaged_file"
  ! "$REPO_ROOT/scripts/restore.sh" --yes "$damaged" >/dev/null 2>&1 || fail "restore accepted a backup with a truncated $damaged_file"
  chat_exists || fail "a refused restore of a truncated $damaged_file deleted the current data"
  [ "$(file_content)" = "$FILE_CONTENT" ] || fail "a refused restore of a truncated $damaged_file deleted the uploaded files"
  pass "a backup with a truncated $damaged_file is refused and the current data stays"
}

assert_data_is_back() {
  chat_exists || fail "the chat did not come back from the backup"
  pass "a deleted chat is back (Open WebUI database)"
  [ "$(file_content)" = "$FILE_CONTENT" ] || fail "the uploaded file did not come back from the backup"
  pass "a deleted uploaded file is back (Open WebUI volume)"
  # Deleting a file in Open WebUI 0.13.3 leaves its vectors in Chroma, so the search can't be "lost" first.
  # The proof is restore.sh: it empties the volume (vector_db/ too) before unpacking the backup.
  file_search_finds_text || fail "file search does not find the deleted file's text after the restore"
  pass "file search finds a deleted file's text again (search index)"
  [ "$(recorded_spend)" = "$SPEND_USD" ] || fail "the spend of $SPEND_EMAIL did not come back (got: $(recorded_spend))"
  pass "a person's deleted spend is back (LiteLLM database)"
}

main() {
  require_tools docker curl jq
  load_env
  assert_failed_chat_restart_is_logged
  assert_chat_is_started_once
  BACKUP_ROOT=$(mktemp -d)
  on_exit_cleanup rm -rf "$BACKUP_ROOT"
  export BACKUP_ROOT # restore.sh's safety backup goes here too, not into backups/
  create_chat
  upload_file
  upload_searchable_file
  create_temporary_customer "$SPEND_EMAIL" "$SPEND_USD"
  sleep 2 # let LiteLLM finish writing the customer before the dump
  local backup_dir
  backup_dir=$("$REPO_ROOT/scripts/backup.sh" | tail -1)
  [ -d "$backup_dir" ] || fail "backup.sh did not report a backup directory (got: $backup_dir)"
  info "backup: $backup_dir"
  assert_chat_runs_after_backup
  assert_damaged_backup_is_refused "$backup_dir" openwebui.dump
  assert_damaged_backup_is_refused "$backup_dir" "$OPENWEBUI_VOLUME.tar.gz"
  lose_the_data
  "$REPO_ROOT/scripts/restore.sh" --yes "$backup_dir" >/dev/null || fail "restore.sh failed"
  assert_data_is_back
}

main "$@"

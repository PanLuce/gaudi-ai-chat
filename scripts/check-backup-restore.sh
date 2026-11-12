#!/usr/bin/env bash
# Checks that a backup brings back real data from all three places it covers:
# a chat (Open WebUI database), an uploaded file (Open WebUI volume) and a person's spend (LiteLLM database).
# NOT for a server people are using: restoring rolls both databases back to the moment of the backup.
# Free: nothing reaches a provider.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

readonly TAG="smoke-backup-$(date +%s)"
readonly SPEND_EMAIL="$TAG@skolagaudi.cz"
readonly SPEND_USD=1.23
readonly FILE_CONTENT="$TAG file content"

CHAT_ID=""
FILE_ID=""
BACKUP_ROOT=""

create_chat() {
  CHAT_ID=$(openwebui_admin POST /api/v1/chats/new \
    "$(jq -cn --arg t "$TAG" '{chat: {title: $t, messages: [], history: {messages: {}}}}')" | jq -er .id) \
    || fail "could not create the test chat"
  on_exit_cleanup openwebui_admin DELETE "/api/v1/chats/$CHAT_ID"
}

# Multipart upload, so not through api_request; the key still travels in a curl config, not argv.
upload_file() {
  local file="$BACKUP_ROOT/$TAG.txt"
  printf '%s' "$FILE_CONTENT" > "$file"
  FILE_ID=$(curl -sS --fail-with-body -X POST "$OPENWEBUI_URL/api/v1/files/?process=false" \
    --config <(printf 'header = "Authorization: Bearer %s"\n' "$OPENWEBUI_ADMIN_API_KEY") \
    -F "file=@$file" | jq -er .id) || fail "could not upload the test file"
  on_exit_cleanup openwebui_admin DELETE "/api/v1/files/$FILE_ID"
}

lose_the_data() {
  openwebui_admin DELETE "/api/v1/chats/$CHAT_ID" >/dev/null || fail "could not delete the test chat"
  openwebui_admin DELETE "/api/v1/files/$FILE_ID" >/dev/null || fail "could not delete the test file"
  delete_litellm_customer "$SPEND_EMAIL"
  ! chat_exists || fail "the test chat is still there after deleting it"
}

chat_exists() { openwebui_admin GET "/api/v1/chats/$CHAT_ID" 2>/dev/null | jq -e --arg t "$TAG" '.title == $t' >/dev/null; }
file_content() { openwebui_admin GET "/api/v1/files/$FILE_ID/content" 2>/dev/null || true; }
recorded_spend() { litellm_admin GET "/customer/info?end_user_id=$SPEND_EMAIL" 2>/dev/null | jq -r '.spend // empty' || true; }

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
  [ "$(recorded_spend)" = "$SPEND_USD" ] || fail "the spend of $SPEND_EMAIL did not come back (got: $(recorded_spend))"
  pass "a person's deleted spend is back (LiteLLM database)"
}

main() {
  require_tools docker curl jq
  load_env
  BACKUP_ROOT=$(mktemp -d)
  on_exit_cleanup rm -rf "$BACKUP_ROOT"
  export BACKUP_ROOT # restore.sh's safety backup goes here too, not into backups/
  create_chat
  upload_file
  create_temporary_customer "$SPEND_EMAIL" "$SPEND_USD"
  sleep 2 # let LiteLLM finish writing the customer before the dump
  local backup_dir
  backup_dir=$("$REPO_ROOT/scripts/backup.sh" | tail -1)
  [ -d "$backup_dir" ] || fail "backup.sh did not report a backup directory (got: $backup_dir)"
  info "backup: $backup_dir"
  assert_damaged_backup_is_refused "$backup_dir" openwebui.dump
  assert_damaged_backup_is_refused "$backup_dir" "$OPENWEBUI_VOLUME.tar.gz"
  lose_the_data
  "$REPO_ROOT/scripts/restore.sh" --yes "$backup_dir" >/dev/null || fail "restore.sh failed"
  assert_data_is_back
}

main "$@"

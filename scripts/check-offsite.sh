#!/usr/bin/env bash
# Checks the copy of backups on the school's Google Drive (scripts/offsite.sh).
# Always, free and offline: a missing setting stops offsite.sh with its name, and rclone gets exactly
# the Drive and encryption settings from .env.
# Only when .env has the Drive settings: a few random files go to Drive under a smoke-offsite-<time> folder,
# come back byte for byte, and the folder is deleted. Chat keeps running.
set -euo pipefail
. "$(dirname "$0")/offsite.sh"

readonly TAG="smoke-offsite-$(date +%s)"

# Run in a subshell: fail exits, and the check needs the message.
assert_missing_setting_is_named() {
  local message
  message=$( (OFFSITE_DRIVE_ID="" require_offsite_settings) 2>&1 ) && fail "offsite.sh goes on without OFFSITE_DRIVE_ID"
  grep -q "add OFFSITE_DRIVE_ID= to .env" <<<"$message" || fail "offsite.sh does not say what to add to .env (got: $message)"
  pass "without the Drive settings, offsite.sh stops and says what to add to .env"
}

# The key is not a real one, so rclone stops at reading it, before it would reach the network.
assert_rclone_gets_the_settings() (
  local work log
  work=$(mktemp -d)
  on_exit_cleanup rm -rf "$work"
  trap run_cleanup EXIT # this subshell's own cleanups, the rclone settings file among them
  printf '{}' > "$work/key.json"
  OFFSITE_DRIVE_ID="$TAG-drive" OFFSITE_SERVICE_ACCOUNT_FILE="$work/key.json" OFFSITE_ENCRYPTION_PASSWORD=$(openssl rand -hex 24)
  BACKUP_ROOT="$work"
  open_rclone_settings
  log=$(offsite_rclone lsd offsite: -vv 2>&1 || true)
  local expected
  for expected in \
    'Setting type=XXX for "offsite"' \
    'Setting remote="gdrive:openwebui-backups" for "offsite"' \
    'Setting password=XXX for "offsite"' \
    'Setting scope="drive" for "gdrive"' \
    "Setting service_account_file=\"$KEY_IN_CONTAINER\" for \"gdrive\"" \
    'Setting team_drive=XXX for "gdrive"' \
    'error processing credentials'; do
    grep -qF "$expected" <<<"$log" || fail "rclone did not get: $expected"
  done
  offsite_rclone listremotes --long 2>/dev/null | grep -Eq '^offsite: +crypt *$' || fail "offsite is not an encrypted (crypt) remote"
  offsite_rclone listremotes --long 2>/dev/null | grep -Eq '^gdrive: +drive *$' || fail "gdrive is not a Google Drive remote"
  pass "rclone gets the shared drive, the robot's key and the encryption password from .env"
)

# On Drive, folders are kept by their name: the newest 30 finished backups stay, a crashed upload
# (.partial) and the check's own smoke folders are never counted as backups.
assert_old_backups_are_chosen_by_name() {
  local folders day removed
  folders=$(for day in $(seq -w 1 31); do echo "202610${day}T023000Z"; done; echo "20261101T023000Z.partial"; echo "$TAG")
  removed=$(backups_to_remove <<<"$folders" | tr '\n' ' ')
  [ "$removed" = "20261001T023000Z " ] || fail "with 31 backups on Drive, the wrong ones would be deleted: '$removed'"
  pass "Google Drive keeps the newest $OFFSITE_KEPT backups and deletes only older finished ones"
}

assert_download_refuses_bad_names() {
  local message work
  message=$("$REPO_ROOT/scripts/offsite.sh" download ../etc 2>&1) && fail "download accepts the name ../etc"
  grep -q "not a backup name" <<<"$message" || fail "download does not say the name is wrong (got: $message)"
  work=$(mktemp -d)
  on_exit_cleanup rm -rf "$work"
  mkdir "$work/20261112T023000Z"
  message=$(BACKUP_ROOT="$work" "$REPO_ROOT/scripts/offsite.sh" download 20261112T023000Z 2>&1) && fail "download overwrites a backup on disk"
  grep -q "already in" <<<"$message" || fail "download does not say the backup is already on disk (got: $message)"
  pass "download takes only a backup name and never overwrites a backup on disk"
}

drive_is_set_up() {
  [ -n "${OFFSITE_DRIVE_ID:-}" ] && [ -n "${OFFSITE_ENCRYPTION_PASSWORD:-}" ] && [ -r "${OFFSITE_SERVICE_ACCOUNT_FILE:-/nonexistent}" ]
}

# Exit action, registered before the rclone settings, so it runs while their file still exists.
delete_offsite_folder() {
  offsite_rclone purge "offsite:$1" >/dev/null 2>&1 || true
  offsite_rclone purge "offsite:$1.partial" >/dev/null 2>&1 || true
}

# A folder of random files goes up under the check's own name, comes back under another and must match
# byte for byte. Synthetic on purpose: a real backup would stop Chat, and backup.sh has its own check.
assert_backup_survives_the_round_trip() {
  local file
  BACKUP_ROOT=$(mktemp -d)
  on_exit_cleanup delete_offsite_folder "$TAG" # before rm: offsite_rclone re-creates BACKUP_ROOT
  on_exit_cleanup rm -rf "$BACKUP_ROOT"
  mkdir "$BACKUP_ROOT/$TAG-source"
  for file in openwebui.dump litellm.dump open-webui-data.tar.gz; do
    head -c 200000 /dev/urandom > "$BACKUP_ROOT/$TAG-source/$file"
  done
  open_rclone_settings
  upload_backup "$TAG-source" "$TAG"
  grep -qx "$TAG" <<<"$(offsite_folders)" || fail "the uploaded folder $TAG is not on Google Drive"
  download_backup "$TAG" "$TAG-back"
  for file in "$BACKUP_ROOT/$TAG-source"/*; do
    cmp -s "$file" "$BACKUP_ROOT/$TAG-back/${file##*/}" || fail "${file##*/} came back from Google Drive different"
  done
  pass "files go to Google Drive encrypted and come back byte for byte"
}

main_check() {
  require_tools docker openssl
  load_env
  assert_missing_setting_is_named
  assert_rclone_gets_the_settings
  assert_old_backups_are_chosen_by_name
  assert_download_refuses_bad_names
  if ! drive_is_set_up; then
    info "NOT RUN: the round trip through Google Drive (.env has no Drive settings yet)"
    return 0
  fi
  require_offsite_settings
  assert_backup_survives_the_round_trip
}

main_check "$@"

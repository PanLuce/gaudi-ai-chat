#!/usr/bin/env bash
# Checks the copy of backups on the school's Google Drive (scripts/offsite.sh).
# Always, free and offline: a missing setting stops offsite.sh with its name, and rclone gets exactly
# the Drive and encryption settings from .env.
# Only when .env has the Drive settings: a real backup goes to Drive under a smoke-offsite-<time> folder,
# comes back byte for byte, and the folder is deleted. Chat stops for a few seconds for that backup.
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
  trap 'rm -rf "$work"' EXIT
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

drive_is_set_up() {
  [ -n "${OFFSITE_DRIVE_ID:-}" ] && [ -n "${OFFSITE_ENCRYPTION_PASSWORD:-}" ] && [ -r "${OFFSITE_SERVICE_ACCOUNT_FILE:-/nonexistent}" ]
}

main_check() {
  require_tools docker openssl
  load_env
  assert_missing_setting_is_named
  assert_rclone_gets_the_settings
  if ! drive_is_set_up; then
    info "NOT RUN: the round trip through Google Drive (.env has no Drive settings yet)"
    return 0
  fi
  fail "the round trip through Google Drive is not written yet"
}

main_check "$@"

#!/usr/bin/env bash
# Copies backups to the school's Google Drive, encrypted, so they survive the loss of the server.
# Usage: scripts/offsite.sh upload             → copies the newest backups/<UTC time>/, keeps the newest 30 on Drive
#        scripts/offsite.sh list               → the backups on Drive and how old the newest one is
#        scripts/offsite.sh download <UTC time> → backups/<UTC time>/, then scripts/restore.sh restores it
# .env: OFFSITE_DRIVE_ID (the shared drive), OFFSITE_SERVICE_ACCOUNT_FILE (the robot's key, outside git),
# OFFSITE_ENCRYPTION_PASSWORD (bootstrap.sh makes it; without it nothing on Drive can be read — keep it
# in the password manager with the rest of .env). docs/adr/0003-zalohy-mimo-server.md says why.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

readonly RCLONE_IMAGE="rclone/rclone:1.75.2"
readonly OFFSITE_KEPT=30
readonly KEY_IN_CONTAINER="/secrets/drive.json"
readonly BACKUP_NAME_PATTERN='^[0-9]{8}T[0-9]{6}Z$'
RCLONE_ENV_FILE=""

require_offsite_settings() {
  local name
  for name in OFFSITE_DRIVE_ID OFFSITE_SERVICE_ACCOUNT_FILE OFFSITE_ENCRYPTION_PASSWORD; do
    [ -n "${!name:-}" ] || fail "add $name= to .env (docs/nasazeni.html, step Zálohy mimo server)"
  done
  case "$OFFSITE_SERVICE_ACCOUNT_FILE" in /*) ;; *) fail "OFFSITE_SERVICE_ACCOUNT_FILE must be a full path starting with /" ;; esac
  [ -r "$OFFSITE_SERVICE_ACCOUNT_FILE" ] || fail "cannot read the Drive key OFFSITE_SERVICE_ACCOUNT_FILE=$OFFSITE_SERVICE_ACCOUNT_FILE"
}

# rclone takes its whole setup from environment variables in a file only we can read: no rclone.conf on
# disk, and the password never appears in argv, where `ps` would show it.
open_rclone_settings() {
  local obscured
  RCLONE_ENV_FILE=$(mktemp)
  on_exit_cleanup rm -f "$RCLONE_ENV_FILE"
  obscured=$(printf '%s' "$OFFSITE_ENCRYPTION_PASSWORD" | docker run --rm -i "$RCLONE_IMAGE" obscure - 2>/dev/null) \
    || fail "could not prepare the encryption password with $RCLONE_IMAGE"
  cat > "$RCLONE_ENV_FILE" <<EOF
RCLONE_CONFIG_GDRIVE_TYPE=drive
RCLONE_CONFIG_GDRIVE_SCOPE=drive
RCLONE_CONFIG_GDRIVE_TEAM_DRIVE=$OFFSITE_DRIVE_ID
RCLONE_CONFIG_GDRIVE_SERVICE_ACCOUNT_FILE=$KEY_IN_CONTAINER
RCLONE_CONFIG_OFFSITE_TYPE=crypt
RCLONE_CONFIG_OFFSITE_REMOTE=gdrive:openwebui-backups
RCLONE_CONFIG_OFFSITE_PASSWORD=$obscured
EOF
}

# Runs as the calling user, so downloaded backups belong to gaudi like the ones backup.sh makes.
# BACKUP_ROOT exists first: Docker would create a missing one owned by root.
offsite_rclone() {
  mkdir -p "$BACKUP_ROOT"
  docker run --rm --user "$(id -u):$(id -g)" --env-file "$RCLONE_ENV_FILE" \
    -v "$OFFSITE_SERVICE_ACCOUNT_FILE:$KEY_IN_CONTAINER:ro" -v "$BACKUP_ROOT:/backups" \
    "$RCLONE_IMAGE" --config "" "$@"
}

# Folder names in, finished backups out, oldest first. Unfinished uploads (.partial) are left out.
finished_backups() {
  { grep -E "$BACKUP_NAME_PATTERN" || true; } | sort
}

# Folder names in, the finished backups beyond the newest OFFSITE_KEPT out.
backups_to_remove() {
  finished_backups | sort -r | tail -n +$((OFFSITE_KEPT + 1))
}

offsite_folders() {
  local folders
  folders=$(offsite_rclone lsf --dirs-only offsite:) || fail "could not read the backups on Google Drive"
  sed 's|/$||' <<<"$folders"
}

offsite_backups() {
  offsite_folders | finished_backups
}

newest_local_backup() {
  local newest
  newest=$(ls -1d "$BACKUP_ROOT"/[0-9]*Z/ 2>/dev/null | sort | tail -1)
  newest=${newest%/}
  echo "${newest##*/}"
}

# Uploads under <name>.partial and renames it after the last byte, like backup.sh does on disk:
# a broken upload never looks like a backup.
upload_backup() {
  local local_name=$1 remote_name=$2
  offsite_rclone purge "offsite:$remote_name.partial" >/dev/null 2>&1 || true
  offsite_rclone copy "/backups/$local_name" "offsite:$remote_name.partial" || fail "could not upload $local_name to Google Drive"
  offsite_rclone moveto "offsite:$remote_name.partial" "offsite:$remote_name" || fail "could not finish the upload of $remote_name"
}

# Deleted folders go to the shared drive's trash, where Google keeps them for 30 more days.
remove_old_offsite_backups() {
  offsite_folders | backups_to_remove | while read -r old; do
    offsite_rclone purge "offsite:$old" || fail "could not delete the old backup $old on Google Drive"
    info "removed old backup $old from Google Drive"
  done
}

upload() {
  local name on_drive
  name=$(newest_local_backup)
  [ -n "$name" ] || fail "no backup in $BACKUP_ROOT to copy (run scripts/backup.sh first)"
  on_drive=$(offsite_backups)
  if grep -qx "$name" <<<"$on_drive"; then
    info "backup $name is already on Google Drive"
  else
    upload_backup "$name" "$name"
  fi
  remove_old_offsite_backups
  pass "backup $name is on Google Drive"
}

hours_since() {
  local t=$1 then
  then=$(date -u -d "${t:0:4}-${t:4:2}-${t:6:2} ${t:9:2}:${t:11:2}:${t:13:2}" +%s 2>/dev/null \
    || date -u -j -f '%Y%m%dT%H%M%SZ' "$t" +%s)
  echo $(( ($(date +%s) - then) / 3600 ))
}

list() {
  local backups newest
  backups=$(offsite_backups)
  [ -n "$backups" ] || fail "no backup on Google Drive yet"
  echo "$backups"
  newest=$(tail -1 <<<"$backups")
  pass "newest on Google Drive: $newest, $(hours_since "$newest") h ago"
}

# Downloads under <name>.partial and renames it after the last byte, so restore.sh never gets half a backup.
download_backup() {
  local remote_name=$1 local_name=$2
  rm -rf "${BACKUP_ROOT:?}/$local_name.partial"
  offsite_rclone copy "offsite:$remote_name" "/backups/$local_name.partial" || fail "could not download $remote_name from Google Drive"
  chmod -R go-rwx "$BACKUP_ROOT/$local_name.partial" # backups hold everyone's chats
  mv "$BACKUP_ROOT/$local_name.partial" "$BACKUP_ROOT/$local_name"
}

# Checked before anything reaches Drive, so a wrong name costs nothing.
require_new_backup_name() {
  grep -Eq "$BACKUP_NAME_PATTERN" <<<"$1" || fail "$1 is not a backup name (see scripts/offsite.sh list)"
  [ ! -e "$BACKUP_ROOT/$1" ] || fail "$1 is already in $BACKUP_ROOT, restore it with scripts/restore.sh $BACKUP_ROOT/$1"
}

download() {
  offsite_backups | grep -qx "$1" || fail "backup $1 is not on Google Drive (see scripts/offsite.sh list)"
  download_backup "$1" "$1"
  pass "backup $1 downloaded, restore it with scripts/restore.sh $BACKUP_ROOT/$1"
  echo "$BACKUP_ROOT/$1"
}

main() {
  local command=${1:-}
  case "$command" in
    upload | list) ;;
    download) require_new_backup_name "${2:-}" ;;
    *) fail "usage: scripts/offsite.sh upload | list | download <UTC time>" ;;
  esac
  require_tools docker
  load_env
  require_offsite_settings
  open_rclone_settings
  "$command" "${@:2}"
}

[ "${BASH_SOURCE[0]}" != "$0" ] || main "$@"

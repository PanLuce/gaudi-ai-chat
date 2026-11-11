#!/usr/bin/env bash
# Restores a backup made by scripts/backup.sh. Everything written since that backup is lost.
# Usage: scripts/restore.sh [--yes] backups/<UTC time>
set -euo pipefail
. "$(dirname "$0")/lib.sh"

readonly APP_SERVICES="caddy open-webui litellm"

confirm() {
  local answer
  read -r -p "Restore $1? Everything since that backup is lost. Type RESTORE: " answer
  [ "$answer" = "RESTORE" ] || fail "cancelled"
}

# Reads every file of the backup in full before anything is stopped or deleted:
# a truncated dump or archive is refused while the current data is still intact.
verify_backup() {
  local database
  for database in $APP_DATABASES; do
    [ -s "$1/$database.dump" ] || fail "$1 has no $database.dump"
    compose exec -T postgres pg_restore -f /dev/null < "$1/$database.dump" 2>/dev/null \
      || fail "$1/$database.dump is damaged, nothing was changed"
  done
  [ -s "$1/$OPENWEBUI_VOLUME.tar.gz" ] || fail "$1 has no $OPENWEBUI_VOLUME.tar.gz"
  docker run --rm -i "$(tools_image)" tar tzf - < "$1/$OPENWEBUI_VOLUME.tar.gz" >/dev/null 2>&1 \
    || fail "$1/$OPENWEBUI_VOLUME.tar.gz is damaged, nothing was changed"
  info "backup $1 is complete and readable"
}

# The current state is backed up first, so a restore can itself be undone.
back_up_current_state() {
  local safety
  safety=$("$REPO_ROOT/scripts/backup.sh" | tail -1) || fail "could not back up the current state, nothing was changed"
  info "current state saved to $safety (restore it if this restore is not what you wanted)"
}

# Dropping and re-creating leaves nothing behind that was created after the backup.
restore_database() {
  local database=$1 dump=$2
  compose exec -T postgres psql -U postgres -v ON_ERROR_STOP=1 -q -c "DROP DATABASE IF EXISTS $database WITH (FORCE)" \
    || fail "could not drop database $database"
  compose run --rm -T db-init >/dev/null || fail "could not re-create database $database"
  compose exec -T postgres pg_restore -U postgres --no-owner --role="$database" -d "$database" < "$dump" \
    || fail "could not restore database $database"
  info "restored database $database"
}

restore_openwebui_files() {
  docker run --rm -i -v "$(compose_volume_name "$OPENWEBUI_VOLUME"):/data" "$(tools_image)" \
    sh -c 'find /data -mindepth 1 -maxdepth 1 ! -name cache -exec rm -rf {} + && tar xzf - -C /data' < "$1" \
    || fail "could not restore $OPENWEBUI_VOLUME"
  info "restored $OPENWEBUI_VOLUME"
}

main() {
  local assume_yes=false dir=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --yes) assume_yes=true ;;
      *) dir=${1%/} ;;
    esac
    shift
  done
  [ -n "$dir" ] || fail "usage: scripts/restore.sh [--yes] backups/<UTC time>"
  require_tools docker jq
  load_env
  verify_backup "$dir"
  $assume_yes || confirm "$dir"
  back_up_current_state
  # shellcheck disable=SC2086
  compose stop $APP_SERVICES
  local database
  for database in $APP_DATABASES; do restore_database "$database" "$dir/$database.dump"; done
  restore_openwebui_files "$dir/$OPENWEBUI_VOLUME.tar.gz"
  compose up -d --wait
  pass "restored $dir"
}

main "$@"

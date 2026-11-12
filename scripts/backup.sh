#!/usr/bin/env bash
# Backs up what cannot be re-created: both databases and Open WebUI's files (uploads, vector index).
# Usage: scripts/backup.sh   → backups/<UTC time>/, keeps the newest 14, prints the directory last.
# .env is not part of the backup: keep a copy in the password manager, a restore needs its secrets.
# Chat (open-webui) is stopped while its database and files are saved, so both are from the same moment
# and the search index (SQLite) is never copied mid-write. The nightly run makes that a few seconds at 2:30.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

readonly BACKUPS_KEPT=14
BACKUP_ROOT="${BACKUP_ROOT:-$REPO_ROOT/backups}"

dump_database() {
  compose exec -T postgres pg_dump -U postgres -Fc "$1" > "$2/$1.dump" || fail "could not dump database $1"
}

archive_openwebui_files() {
  docker run --rm -v "$(compose_volume_name "$OPENWEBUI_VOLUME"):/data:ro" "$(tools_image)" \
    tar czf - -C /data --exclude ./cache . > "$1/$OPENWEBUI_VOLUME.tar.gz" || fail "could not archive $OPENWEBUI_VOLUME"
}

readonly CHAT_SERVICE="open-webui"
readonly CHAT_DATABASE="openwebui" # saved while Chat is stopped, together with its files

# Registered as an exit action too, so Chat comes back even when the backup fails halfway.
start_chat() {
  compose up -d --wait "$CHAT_SERVICE" >/dev/null 2>&1 || fail "Chat ($CHAT_SERVICE) did not start again after the backup"
}

stop_chat() {
  on_exit_cleanup start_chat
  compose stop "$CHAT_SERVICE" >/dev/null 2>&1 || fail "could not stop Chat ($CHAT_SERVICE) for the backup"
}

remove_old_backups() {
  ls -1d "$BACKUP_ROOT"/[0-9]*Z/ 2>/dev/null | sort -r | tail -n +$((BACKUPS_KEPT + 1)) | while read -r old; do
    rm -rf "$old"
    info "removed old backup $old"
  done
}

main() {
  require_tools docker jq
  load_env
  local dir partial stopped_at database
  umask 077 # backups hold everyone's chats
  dir="$BACKUP_ROOT/$(date -u +%Y%m%dT%H%M%SZ)"
  partial="$dir.partial" # an interrupted backup never looks like a complete one
  mkdir -p "$partial"
  for database in $APP_DATABASES; do
    [ "$database" = "$CHAT_DATABASE" ] || dump_database "$database" "$partial"
  done
  stopped_at=$(date +%s)
  stop_chat
  dump_database "$CHAT_DATABASE" "$partial"
  archive_openwebui_files "$partial"
  start_chat
  info "chat stopped for $(( $(date +%s) - stopped_at )) s"
  mv "$partial" "$dir"
  remove_old_backups
  pass "backup complete"
  echo "$dir"
}

main "$@"

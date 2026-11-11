#!/bin/sh
# Idempotently creates one role + database per application. Runs on every `docker compose up`
# (service db-init), so adding an application later only means adding one line below.
# Passwords are generated hex strings (scripts/bootstrap.sh), so they need no SQL quoting.
set -eu

ensure_database() {
  name=$1
  password=$2
  psql -v ON_ERROR_STOP=1 -q <<SQL
DO \$\$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '$name') THEN
    CREATE ROLE $name LOGIN PASSWORD '$password';
  ELSE
    ALTER ROLE $name PASSWORD '$password';
  END IF;
END \$\$;
SQL
  if ! psql -tAc "SELECT 1 FROM pg_database WHERE datname = '$name'" | grep -q 1; then
    psql -v ON_ERROR_STOP=1 -q -c "CREATE DATABASE $name OWNER $name"
  fi
  echo "database ready: $name"
}

ensure_database litellm "$LITELLM_DB_PASSWORD"
ensure_database openwebui "$OPENWEBUI_DB_PASSWORD"

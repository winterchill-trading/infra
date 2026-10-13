#!/usr/bin/env bash
# Creates one login role and one database per application. The postgres image
# runs this once, on an empty data directory; later starts skip it, so a
# changed password here does not reach an existing cluster (ALTER ROLE it, or
# `make reset-data CONFIRM=yes` locally).
#
# Passwords come from the environment. Compose and the chart's dev profile set
# development defaults; anything else sets its own.
set -euo pipefail

create_database() {
  local name=$1 password=$2
  # psql's :"name" and :'password' quote the identifier and the literal.
  psql -v ON_ERROR_STOP=1 --no-psqlrc --username "$POSTGRES_USER" --dbname postgres \
    -v name="$name" -v password="$password" <<'SQL'
CREATE ROLE :"name" LOGIN PASSWORD :'password';
CREATE DATABASE :"name" OWNER :"name";
REVOKE ALL ON DATABASE :"name" FROM PUBLIC;
SQL
  echo "initdb: database $name, owner $name"
}

create_database neobank "${NEOBANK_DB_PASSWORD:?NEOBANK_DB_PASSWORD is not set}"
create_database hl_copy "${HL_COPY_DB_PASSWORD:?HL_COPY_DB_PASSWORD is not set}"

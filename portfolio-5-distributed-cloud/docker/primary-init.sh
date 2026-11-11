#!/bin/bash
# Runs once, when the primary's data directory is first created.
# Creates the replication user and allows replicas to connect for streaming.
set -e
psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" <<'SQL'
CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD 'finesse';
SQL
echo "host replication replicator all scram-sha-256" >> "$PGDATA/pg_hba.conf"

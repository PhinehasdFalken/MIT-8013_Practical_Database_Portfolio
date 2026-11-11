#!/bin/bash
# Entry point of the two replica containers.
# On first start it CLONES the primary with pg_basebackup (full copy + WAL), configures the
# node as a hot standby and then starts PostgreSQL. Later starts reuse the existing copy.
set -e
PGDATA=/var/lib/postgresql/data

if [ ! -s "$PGDATA/PG_VERSION" ]; then
  echo "[$REPLICA_NAME] waiting for the primary ..."
  until pg_isready -h fk-primary -p 5432 -U postgres -q; do sleep 1; done
  sleep 3                                   # let the primary finish its first-time initialisation
  until pg_isready -h fk-primary -p 5432 -U postgres -q; do sleep 1; done

  echo "[$REPLICA_NAME] cloning the primary with pg_basebackup ..."
  mkdir -p "$PGDATA" && chown postgres:postgres "$PGDATA" && chmod 700 "$PGDATA"
  # -R  writes standby.signal + primary_conninfo  (start as a replica)
  # -X stream  copies the WAL produced during the backup
  # -C -S      creates a replication slot so the primary keeps WAL until this replica has it
  gosu postgres pg_basebackup -h fk-primary -p 5432 -U replicator -D "$PGDATA" \
       -R -X stream -C -S "${REPLICA_NAME}_slot" --checkpoint=fast

  # identify this standby by name (needed for synchronous_standby_names = 'replica1')
  echo "primary_conninfo = 'host=fk-primary port=5432 user=replicator password=${PGPASSWORD} application_name=${REPLICA_NAME}'" \
       | gosu postgres tee -a "$PGDATA/postgresql.auto.conf" > /dev/null
  if [ "$APPLY_DELAY" != "0" ]; then
    echo "recovery_min_apply_delay = '${APPLY_DELAY}'" | gosu postgres tee -a "$PGDATA/postgresql.auto.conf" > /dev/null
  fi
fi

exec docker-entrypoint.sh postgres -c cluster_name="$REPLICA_NAME" -c hot_standby=on -c listen_addresses='*'

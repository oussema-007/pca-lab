#!/bin/bash
# PostgreSQL streaming replica bootstrap (phase 6). First start: pg_basebackup from the primary "db" using slot replica1,
# -R writes standby.signal + primary_conninfo. Next starts: just run postgres in hot standby.
set -euo pipefail
mkdir -p "$PGDATA"; chown -R postgres:postgres "$(dirname "$PGDATA")"; chmod 700 "$PGDATA"
if [ ! -s "$PGDATA/PG_VERSION" ]; then
  until pg_isready -h db -U replicator -q; do echo "waiting for primary"; sleep 1; done
  echo "initial base backup from primary (slot replica1)"
  gosu postgres pg_basebackup -h db -U replicator -D "$PGDATA" -X stream -S replica1 -R -c fast
fi
exec gosu postgres postgres -c hot_standby=on -c max_connections=200 -c shared_buffers=64MB \
  -c wal_level=replica -c max_wal_senders=5 -c hot_standby_feedback=on

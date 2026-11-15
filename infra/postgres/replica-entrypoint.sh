
set -euo pipefail
PGDATA=/var/lib/postgresql/data

mkdir -p "$PGDATA"
chown -R postgres:postgres "$PGDATA"
chmod 700 "$PGDATA"

if [ ! -s "$PGDATA/PG_VERSION" ]; then
  echo "[replica] empty data directory - taking base backup from pg-primary ..."
  until pg_isready -h pg-primary -p 5432 -U gc >/dev/null 2>&1; do sleep 1; done
  gosu postgres env PGPASSWORD=replicator_local_only \
    pg_basebackup -h pg-primary -p 5432 -U replicator -D "$PGDATA" \
                  -X stream -R -S replica1_slot --checkpoint=fast --progress
  echo "[replica] base backup complete"
fi


exec gosu postgres postgres \
  -c hot_standby=on \
  -c timezone=Africa/Lagos \
  -c cluster_name=replica1 \
  -c hot_standby_feedback=on


set -e

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<'SQL'
CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD 'replicator_local_only';
SELECT pg_create_physical_replication_slot('replica1_slot');
SQL


echo "host replication replicator all scram-sha-256" >> "$PGDATA/pg_hba.conf"

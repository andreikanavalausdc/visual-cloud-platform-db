set -Eeuo pipefail

test -f "$PGDATA/.vcp-initialized"
pg_isready -q -h 127.0.0.1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"
psql -X -q -t -A -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c \
    "SELECT count(*)=3 FROM app.schema_migrations WHERE version IN (1,2,3);" | grep -qx t

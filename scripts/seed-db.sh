#!/usr/bin/env bash
# Creates the tables and loads the seed data from db/*.sql into the in-cluster PostgreSQL.
# Each file is streamed through `kubectl exec`, and psql reads the credentials from the env vars
# the Deployment injected into the pod, so no port-forward, local psql or local password is needed.
# Safe to re-run: seeding is skipped when the tables already exist.
set -euo pipefail

cd "$(dirname "$0")/.."
DB_DEPLOYMENT="${DB_DEPLOYMENT:-deployment/postgresql}"

psql_in_pod() {
  kubectl exec -i "$DB_DEPLOYMENT" -- sh -c \
    'PGPASSWORD="$POSTGRES_PASSWORD" psql -v ON_ERROR_STOP=1 -q -U "$POSTGRES_USER" -d "$POSTGRES_DB" "$@"' psql "$@"
}

kubectl rollout status "$DB_DEPLOYMENT" --timeout=180s

if [ "$(psql_in_pod -tAc "SELECT to_regclass('public.tokens') IS NOT NULL" < /dev/null)" = "t" ]; then
  echo "Tables already exist - skipping seed."
else
  for sql_file in db/*.sql; do
    echo "Applying $sql_file"
    psql_in_pod < "$sql_file"
  done
fi

psql_in_pod -c "SELECT (SELECT count(*) FROM users) AS users, (SELECT count(*) FROM tokens) AS tokens;" < /dev/null

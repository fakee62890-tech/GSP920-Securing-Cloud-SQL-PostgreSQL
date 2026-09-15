#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ID="$(gcloud config get-value project 2>/dev/null)"
INSTANCE="${CLOUDSQL_INSTANCE:-postgres-orders}"
ROOT_PASSWORD="${CLOUDSQL_ROOT_PASSWORD:-supersecret!}"
export PGPASSWORD="$ROOT_PASSWORD"

gcloud sql instances describe "$INSTANCE" --project="$PROJECT_ID" >/dev/null
gcloud sql instances patch "$INSTANCE" --project="$PROJECT_ID" \
  --database-flags='cloudsql.enable_pgaudit=on,pgaudit.log=all' --quiet

echo "Waiting for Cloud SQL operation to finish..."
for i in {1..30}; do
  STATUS="$(gcloud sql instances describe "$INSTANCE" --format='value(state)' 2>/dev/null || true)"
  [[ "$STATUS" == "RUNNABLE" ]] && break
  sleep 10
done

# Restart is required by the lab after changing pgAudit flags.
gcloud sql instances restart "$INSTANCE" --project="$PROJECT_ID" --quiet || true
for i in {1..36}; do
  STATUS="$(gcloud sql instances describe "$INSTANCE" --format='value(state)' 2>/dev/null || true)"
  echo "Cloud SQL state: ${STATUS:-unknown}"
  [[ "$STATUS" == "RUNNABLE" ]] && break
  sleep 10
done

WORKDIR="${HOME}/gsp920-data"
mkdir -p "$WORKDIR"
cd "$WORKDIR"
SOURCE_BUCKET="gs://spls/gsp920"
for f in create_orders_db.sql DDL/distribution_centers_data.csv DDL/inventory_items_data.csv DDL/order_items_data.csv DDL/products_data.csv DDL/users_data.csv; do
  gcloud storage cp "${SOURCE_BUCKET}/${f}" . 2>/dev/null || gcloud storage cp "${SOURCE_BUCKET}/${f}" "${WORKDIR}/$(basename "$f")"
done
POSTGRESQL_IP="$(gcloud sql instances describe "$INSTANCE" --format='value(ipAddresses[0].ipAddress)')"
export POSTGRESQL_IP
psql "sslmode=disable user=postgres hostaddr=${POSTGRESQL_IP}" -v ON_ERROR_STOP=1 -c '\i create_orders_db.sql'
psql "sslmode=disable user=postgres hostaddr=${POSTGRESQL_IP} dbname=orders" -v ON_ERROR_STOP=1 <<'SQL'
CREATE EXTENSION IF NOT EXISTS pgaudit;
ALTER DATABASE orders SET pgaudit.log = 'read,write';
DO $$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'auditor') THEN
    CREATE ROLE auditor WITH NOLOGIN;
  END IF;
END $$;
GRANT SELECT ON order_items TO auditor;
ALTER DATABASE orders SET pgaudit.role = 'auditor';
SQL
# Add Cloud SQL Data Access logging configuration at project level (auditing is usually already enabled by lab UI).
TMP="$(mktemp)"
gcloud projects get-iam-policy "$PROJECT_ID" --format=json > "$TMP"
python3 - "$TMP" <<'PY'
import json,sys
p=sys.argv[1]
d=json.load(open(p))
configs=d.setdefault('auditConfigs',[])
entry=next((x for x in configs if x.get('service')=='sqladmin.googleapis.com'),None)
if not entry:
    configs.append({'service':'sqladmin.googleapis.com','auditLogConfigs':[{'logType':'ADMIN_READ'},{'logType':'DATA_READ'},{'logType':'DATA_WRITE'}]})
else:
    types={x.get('logType') for x in entry.setdefault('auditLogConfigs',[])}
    for t in ('ADMIN_READ','DATA_READ','DATA_WRITE'):
        if t not in types: entry['auditLogConfigs'].append({'logType':t})
json.dump(d,open(p,'w'))
PY
gcloud projects set-iam-policy "$PROJECT_ID" "$TMP" --quiet >/dev/null || echo "Note: project audit policy could not be changed; enable Cloud SQL audit logs in Console."
rm -f "$TMP"
echo "DONE: pgAudit configured and orders data populated. Run next: gsp920-03-iam.sh"

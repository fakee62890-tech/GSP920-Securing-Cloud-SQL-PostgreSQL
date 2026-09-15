#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ID="$(gcloud config get-value project 2>/dev/null)"
INSTANCE="${CLOUDSQL_INSTANCE:-postgres-orders}"
ROOT_PASSWORD="${CLOUDSQL_ROOT_PASSWORD:-supersecret!}"
USERNAME="$(gcloud config get-value account 2>/dev/null)"
[[ -n "$USERNAME" && "$USERNAME" != "(unset)" ]] || { echo "ERROR: active gcloud account nahi mila." >&2; exit 1; }

echo "Creating Cloud IAM database user: $USERNAME"
gcloud sql users create "$USERNAME" --instance="$INSTANCE" --project="$PROJECT_ID" --type=cloud_iam_user --quiet 2>/dev/null || \
  echo "IAM user already exists or console-created user was found; continuing."

POSTGRESQL_IP="$(gcloud sql instances describe "$INSTANCE" --project="$PROJECT_ID" --format='value(ipAddresses[0].ipAddress)')"
export PGPASSWORD="$ROOT_PASSWORD"
psql "sslmode=disable user=postgres hostaddr=${POSTGRESQL_IP} dbname=orders" -v ON_ERROR_STOP=1 <<SQL
GRANT ALL PRIVILEGES ON TABLE order_items TO "$USERNAME";
SQL

# Test IAM authentication and the expected table-level permission boundary.
export PGPASSWORD="$(gcloud auth print-access-token)"
IAM_OUTPUT="$(psql --host="$POSTGRESQL_IP" "$USERNAME" --dbname=orders -v ON_ERROR_STOP=1 -c 'SELECT COUNT(*) AS order_items_count FROM order_items;' 2>&1)" || {
  echo "$IAM_OUTPUT"
  echo "IAM login test failed. Ensure the instance is RUNNABLE and Cloud SQL Admin API has propagated." >&2
  exit 1
}
echo "$IAM_OUTPUT"

if psql --host="$POSTGRESQL_IP" "$USERNAME" --dbname=orders -v ON_ERROR_STOP=1 -c 'SELECT COUNT(*) FROM users;' >/dev/null 2>&1; then
  echo "WARNING: users table was readable; lab may require revoking inherited/public permissions."
else
  echo "Verified: IAM user can read order_items but cannot read users."
fi

echo "DONE: Cloud SQL IAM database authentication configured and tested."
echo "Expected lab completion time: about 20-35 minutes total, mostly Cloud SQL create/restart waits."

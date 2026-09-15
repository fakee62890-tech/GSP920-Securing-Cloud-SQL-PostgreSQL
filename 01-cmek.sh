#!/usr/bin/env bash
set -Eeuo pipefail
PROJECT_ID="$(gcloud config get-value project 2>/dev/null)"
[[ -n "$PROJECT_ID" && "$PROJECT_ID" != "(unset)" ]] || { echo "ERROR: gcloud project set nahi hai." >&2; exit 1; }
# This challenge project rejects us-central1 by org policy. Override only if
# your lab explicitly provides another allowed region: REGION=region ./01-cmek-v2.sh
REGION="${REGION:-us-east4}"
KEYRING="${KMS_KEYRING_ID:-cloud-sql-keyring}"
KEY="${KMS_KEY_ID:-cloud-sql-key}"
INSTANCE="${CLOUDSQL_INSTANCE:-postgres-orders}"
ROOT_PASSWORD="${CLOUDSQL_ROOT_PASSWORD:-supersecret!}"
echo "Project: $PROJECT_ID | Region: $REGION | Instance: $INSTANCE"
gcloud services enable sqladmin.googleapis.com cloudkms.googleapis.com --project="$PROJECT_ID"
gcloud beta services identity create --service=sqladmin.googleapis.com --project="$PROJECT_ID" >/dev/null || true
gcloud kms keyrings describe "$KEYRING" --location="$REGION" >/dev/null 2>&1 || gcloud kms keyrings create "$KEYRING" --location="$REGION"
gcloud kms keys describe "$KEY" --keyring="$KEYRING" --location="$REGION" >/dev/null 2>&1 || gcloud kms keys create "$KEY" --location="$REGION" --keyring="$KEYRING" --purpose=encryption
PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"
gcloud kms keys add-iam-policy-binding "$KEY" --location="$REGION" --keyring="$KEYRING" --member="serviceAccount:service-${PROJECT_NUMBER}@gcp-sa-cloud-sql.iam.gserviceaccount.com" --role=roles/cloudkms.cryptoKeyEncrypterDecrypter --quiet >/dev/null
KEY_NAME="$(gcloud kms keys describe "$KEY" --keyring="$KEYRING" --location="$REGION" --format='value(name)')"
BASTION_ZONE="$(gcloud compute instances describe bastion-vm --format='value(zone)' 2>/dev/null | awk -F/ '{print $NF}' || true)"
AUTHORIZED_IP=""
if [[ -n "$BASTION_ZONE" ]]; then AUTHORIZED_IP="$(gcloud compute instances describe bastion-vm --zone="$BASTION_ZONE" --format='value(networkInterfaces[0].accessConfigs[0].natIP)' 2>/dev/null || true)"; fi
CLOUD_SHELL_IP="$(curl -fsS https://ifconfig.me || true)"
NETWORKS=""
[[ -n "$AUTHORIZED_IP" ]] && NETWORKS="${AUTHORIZED_IP}/32"
[[ -n "$CLOUD_SHELL_IP" ]] && NETWORKS="${NETWORKS:+$NETWORKS,}${CLOUD_SHELL_IP}/32"
[[ -n "$NETWORKS" ]] || { echo "ERROR: authorized network IP nahi mili." >&2; exit 1; }
if gcloud sql instances describe "$INSTANCE" --project="$PROJECT_ID" >/dev/null 2>&1; then
  echo "Cloud SQL instance already exists; create step skipped."
else
  gcloud sql instances create "$INSTANCE" --project="$PROJECT_ID" --authorized-networks="$NETWORKS" --disk-encryption-key="$KEY_NAME" --database-version=POSTGRES_14 --cpu=1 --memory=3840MB --region="$REGION" --root-password="$ROOT_PASSWORD" --quiet
fi
echo "DONE: CMEK-enabled Cloud SQL instance ready: $INSTANCE"
echo "Run next: 02-pgaudit.sh"

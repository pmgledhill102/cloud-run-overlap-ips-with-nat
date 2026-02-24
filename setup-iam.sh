#!/usr/bin/env bash
#
# setup-iam.sh — Create service account and bind IAM roles
#
# Run this with your own privileged account (Owner or IAM Admin).
# After this completes, use the created service account to run setup-infra.sh.
#
set -euo pipefail

PROJECT_ID="${PROJECT_ID:-sb-paul-g-workshop}"

SA_NAME="cloud-run-nat-poc"
SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

echo "=== Setup IAM for project: ${PROJECT_ID} ==="
echo "Service account: ${SA_EMAIL}"
echo ""

# --- Enable APIs ---
echo "--- Enabling APIs ---"
gcloud services enable \
  compute.googleapis.com \
  run.googleapis.com \
  vpcaccess.googleapis.com \
  iap.googleapis.com \
  artifactregistry.googleapis.com \
  networkconnectivity.googleapis.com \
  cloudbuild.googleapis.com \
  --project="${PROJECT_ID}"
echo "APIs enabled."

# --- Create service account ---
echo ""
echo "--- Creating service account ---"
if gcloud iam service-accounts describe "${SA_EMAIL}" --project="${PROJECT_ID}" &>/dev/null; then
  echo "Service account already exists, skipping."
else
  gcloud iam service-accounts create "${SA_NAME}" \
    --display-name="Cloud Run NAT PoC" \
    --description="Service account for Cloud Run overlapping IP PoC" \
    --project="${PROJECT_ID}"
  echo "Service account created."
fi

# --- Bind IAM roles ---
echo ""
echo "--- Binding IAM roles ---"
ROLES=(
  roles/compute.networkAdmin
  roles/compute.instanceAdmin.v1
  roles/run.admin
  roles/run.invoker
  roles/vpcaccess.admin
  roles/iam.serviceAccountUser
  roles/iap.tunnelResourceAccessor
  roles/artifactregistry.admin
  roles/networkconnectivity.hubAdmin
)

for role in "${ROLES[@]}"; do
  echo "  Binding ${role}..."
  gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="${role}" \
    --condition=None \
    --quiet >/dev/null
done
echo "IAM roles bound."

# --- Grant Cloud Run Service Agent compute.networkUser ---
echo ""
echo "--- Granting Cloud Run Service Agent roles/compute.networkUser ---"
PROJECT_NUMBER="$(gcloud projects describe "${PROJECT_ID}" --format='value(projectNumber)')"
CR_SA="service-${PROJECT_NUMBER}@serverless-robot-prod.iam.gserviceaccount.com"
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${CR_SA}" \
  --role="roles/compute.networkUser" \
  --condition=None \
  --quiet >/dev/null
echo "Cloud Run Service Agent granted compute.networkUser."

# --- Summary ---
echo ""
echo "=== Done ==="
echo ""
echo "Service account: ${SA_EMAIL}"
echo ""
echo "To impersonate this SA for setup-infra.sh:"
echo "  gcloud config set auth/impersonate_service_account ${SA_EMAIL}"
echo ""
echo "To stop impersonating:"
echo "  gcloud config unset auth/impersonate_service_account"

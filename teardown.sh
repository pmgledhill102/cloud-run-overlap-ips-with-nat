#!/usr/bin/env bash
#
# teardown.sh — Destroy all infrastructure (idempotent)
#
# Safe to re-run: skips resources that don't exist.
#
set -euo pipefail

PROJECT_ID="$(gcloud config get-value project 2>/dev/null)"
if [[ -z "$PROJECT_ID" ]]; then
  echo "ERROR: No project set. Run: gcloud config set project <PROJECT_ID>"
  exit 1
fi

REGION="europe-north2"
ZONE="${REGION}-a"
REPO_NAME="cloud-run-nat-poc"
COMPUTE_INSTANCE_NAME="nat-poc-vm"
SA_NAME="cloud-run-nat-poc"
SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
MAX_CONCURRENT_DELETES=5

NUM_VPCS=2
NUM_SUBNETS_PER_VPC=3
NUM_SERVICES_PER_SUBNET=3

CLASS_E_BASES=(240 241 242)

echo "=== Teardown Infrastructure for project: ${PROJECT_ID} ==="
echo ""

# --- Helper ---
resource_exists() {
  "$@" &>/dev/null
  return $?
}

# --- Step 1: Delete Compute Instance ---
echo "--- Step 1: Delete Compute Instance ---"
if resource_exists gcloud compute instances describe "${COMPUTE_INSTANCE_NAME}" \
    --zone="${ZONE}" --project="${PROJECT_ID}"; then
  gcloud compute instances delete "${COMPUTE_INSTANCE_NAME}" \
    --zone="${ZONE}" --project="${PROJECT_ID}" --quiet
  echo "Instance '${COMPUTE_INSTANCE_NAME}' deleted."
else
  echo "Instance '${COMPUTE_INSTANCE_NAME}' does not exist, skipping."
fi

# --- Step 2: Delete Cloud Run services ---
echo ""
echo "--- Step 2: Delete Cloud Run services ---"
delete_count=0
running_jobs=0

for v in $(seq 1 ${NUM_VPCS}); do
  for s in $(seq 0 $((NUM_SUBNETS_PER_VPC - 1))); do
    for i in $(seq 1 ${NUM_SERVICES_PER_SUBNET}); do
      service_name="cr-v${v}-s$((s + 1))-$(printf '%02d' ${i})"

      if ! resource_exists gcloud run services describe "${service_name}" \
          --region="${REGION}" --project="${PROJECT_ID}"; then
        continue
      fi

      echo "Deleting '${service_name}'..."
      gcloud run services delete "${service_name}" \
        --region="${REGION}" --project="${PROJECT_ID}" --quiet &

      running_jobs=$((running_jobs + 1))
      delete_count=$((delete_count + 1))

      if [[ ${running_jobs} -ge ${MAX_CONCURRENT_DELETES} ]]; then
        wait -n
        running_jobs=$((running_jobs - 1))
      fi
    done
  done
done
wait
echo "Deleted ${delete_count} Cloud Run services."

# --- Step 3: Delete firewall rules ---
echo ""
echo "--- Step 3: Delete firewall rules ---"

for v in $(seq 1 ${NUM_VPCS}); do
  fw_name="allow-internal-${v}"
  if resource_exists gcloud compute firewall-rules describe "${fw_name}" --project="${PROJECT_ID}"; then
    gcloud compute firewall-rules delete "${fw_name}" --project="${PROJECT_ID}" --quiet
    echo "Firewall rule '${fw_name}' deleted."
  else
    echo "Firewall rule '${fw_name}' does not exist, skipping."
  fi
done

FW_IAP="allow-iap-ssh-vpc-${NUM_VPCS}"
if resource_exists gcloud compute firewall-rules describe "${FW_IAP}" --project="${PROJECT_ID}"; then
  gcloud compute firewall-rules delete "${FW_IAP}" --project="${PROJECT_ID}" --quiet
  echo "Firewall rule '${FW_IAP}' deleted."
else
  echo "Firewall rule '${FW_IAP}' does not exist, skipping."
fi

# --- Step 4: Delete subnets ---
echo ""
echo "--- Step 4: Delete subnets ---"

# Compute subnet
COMPUTE_SUBNET_NAME="compute-subnet"
if resource_exists gcloud compute networks subnets describe "${COMPUTE_SUBNET_NAME}" \
    --region="${REGION}" --project="${PROJECT_ID}"; then
  gcloud compute networks subnets delete "${COMPUTE_SUBNET_NAME}" \
    --region="${REGION}" --project="${PROJECT_ID}" --quiet
  echo "Subnet '${COMPUTE_SUBNET_NAME}' deleted."
else
  echo "Subnet '${COMPUTE_SUBNET_NAME}' does not exist, skipping."
fi

# Routable subnets
for v in $(seq 1 ${NUM_VPCS}); do
  subnet_name="routable-${v}"
  if resource_exists gcloud compute networks subnets describe "${subnet_name}" \
      --region="${REGION}" --project="${PROJECT_ID}"; then
    gcloud compute networks subnets delete "${subnet_name}" \
      --region="${REGION}" --project="${PROJECT_ID}" --quiet
    echo "Subnet '${subnet_name}' deleted."
  else
    echo "Subnet '${subnet_name}' does not exist, skipping."
  fi
done

# Class E subnets
for v in $(seq 1 ${NUM_VPCS}); do
  for s in $(seq 0 $((NUM_SUBNETS_PER_VPC - 1))); do
    base="${CLASS_E_BASES[$s]}"
    subnet_name="class-e-${base}-vpc-${v}"

    if resource_exists gcloud compute networks subnets describe "${subnet_name}" \
        --region="${REGION}" --project="${PROJECT_ID}"; then
      gcloud compute networks subnets delete "${subnet_name}" \
        --region="${REGION}" --project="${PROJECT_ID}" --quiet
      echo "Subnet '${subnet_name}' deleted."
    else
      echo "Subnet '${subnet_name}' does not exist, skipping."
    fi
  done
done

# --- Step 5: Delete VPC networks ---
echo ""
echo "--- Step 5: Delete VPC networks ---"
for v in $(seq 1 ${NUM_VPCS}); do
  vpc_name="vpc-${v}"
  if resource_exists gcloud compute networks describe "${vpc_name}" --project="${PROJECT_ID}"; then
    gcloud compute networks delete "${vpc_name}" --project="${PROJECT_ID}" --quiet
    echo "VPC '${vpc_name}' deleted."
  else
    echo "VPC '${vpc_name}' does not exist, skipping."
  fi
done

# --- Step 6: Delete Artifact Registry repo ---
echo ""
echo "--- Step 6: Delete Artifact Registry repository ---"
if resource_exists gcloud artifacts repositories describe "${REPO_NAME}" \
    --location="${REGION}" --project="${PROJECT_ID}"; then
  gcloud artifacts repositories delete "${REPO_NAME}" \
    --location="${REGION}" --project="${PROJECT_ID}" --quiet
  echo "Repository '${REPO_NAME}' deleted."
else
  echo "Repository '${REPO_NAME}' does not exist, skipping."
fi

# --- Step 7: Remove IAM bindings ---
echo ""
echo "--- Step 7: Remove IAM bindings ---"
if gcloud iam service-accounts describe "${SA_EMAIL}" --project="${PROJECT_ID}" &>/dev/null; then
  ROLES=(
    roles/compute.networkAdmin
    roles/compute.instanceAdmin.v1
    roles/run.admin
    roles/vpcaccess.admin
    roles/iam.serviceAccountUser
    roles/iap.tunnelResourceAccessor
    roles/artifactregistry.admin
    roles/networkconnectivity.hubAdmin
  )
  for role in "${ROLES[@]}"; do
    echo "  Removing ${role}..."
    gcloud projects remove-iam-policy-binding "${PROJECT_ID}" \
      --member="serviceAccount:${SA_EMAIL}" \
      --role="${role}" \
      --quiet >/dev/null 2>&1 || true
  done
  echo "IAM bindings removed."
else
  echo "Service account does not exist, skipping IAM cleanup."
fi

# Remove Cloud Run Service Agent binding
PROJECT_NUMBER="$(gcloud projects describe "${PROJECT_ID}" --format='value(projectNumber)' 2>/dev/null || true)"
if [[ -n "${PROJECT_NUMBER}" ]]; then
  CR_SA="service-${PROJECT_NUMBER}@serverless-robot-prod.iam.gserviceaccount.com"
  gcloud projects remove-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${CR_SA}" \
    --role="roles/compute.networkUser" \
    --quiet >/dev/null 2>&1 || true
  echo "Cloud Run Service Agent binding removed."
fi

# --- Step 8: Delete service account ---
echo ""
echo "--- Step 8: Delete service account ---"
if gcloud iam service-accounts describe "${SA_EMAIL}" --project="${PROJECT_ID}" &>/dev/null; then
  gcloud iam service-accounts delete "${SA_EMAIL}" --project="${PROJECT_ID}" --quiet
  echo "Service account '${SA_EMAIL}' deleted."
else
  echo "Service account '${SA_EMAIL}' does not exist, skipping."
fi

echo ""
echo "=== Teardown complete ==="

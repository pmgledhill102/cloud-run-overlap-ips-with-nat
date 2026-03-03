#!/usr/bin/env bash
#
# shared/teardown-hub.sh — Tear down shared hub infrastructure (idempotent)
#
# Deletes VM, hub firewall rules, hub subnet, hub VPC, Artifact Registry,
# IAM bindings, and service account.
#
# Safety: checks for remaining spoke VPCs before deleting hub resources.
#
# Called by: direct-vpc-egress/teardown.sh, vpc-connector/teardown.sh
#
set -euo pipefail

PROJECT_ID="${PROJECT_ID:-sb-paul-g-workshop}"

REGION="europe-north2"
ZONE="${REGION}-a"
REPO_NAME="cloud-run-nat-poc"
SA_NAME="cloud-run-nat-poc"
SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

echo "=== Teardown Hub Infrastructure for project: ${PROJECT_ID} ==="
echo ""

# --- Helpers ---
resource_exists() {
  "$@" &>/dev/null
  return $?
}

FAILED_RESOURCES=()

# ============================================================
# Guard: check for remaining spoke VPCs
# ============================================================
echo "--- Checking for remaining spoke VPCs ---"
REMAINING_SPOKES=()
for vpc in spoke-1 spoke-2 spoke-c1 spoke-c2; do
  if resource_exists gcloud compute networks describe "${vpc}" --project="${PROJECT_ID}"; then
    REMAINING_SPOKES+=("${vpc}")
  fi
done

if [[ ${#REMAINING_SPOKES[@]} -gt 0 ]]; then
  echo "WARNING: Spoke VPCs still exist: ${REMAINING_SPOKES[*]}"
  echo "Hub resources are shared. Skipping hub teardown."
  echo "Delete spoke VPCs first, then re-run this script."
  exit 0
fi

echo "No spoke VPCs found. Proceeding with hub teardown."

# ============================================================
# Step 1: Delete Compute VM
# ============================================================
echo ""
echo "--- Step 1: Delete Compute VM ---"
if resource_exists gcloud compute instances describe "vm-hub" \
    --zone="${ZONE}" --project="${PROJECT_ID}"; then
  gcloud compute instances delete "vm-hub" \
    --zone="${ZONE}" --project="${PROJECT_ID}" --quiet
  echo "Instance 'vm-hub' deleted."
else
  echo "Instance 'vm-hub' does not exist, skipping."
fi

# ============================================================
# Step 2: Delete hub NAT (Public NAT for VM internet access)
# ============================================================
echo ""
echo "--- Step 2: Delete hub NAT ---"
if gcloud compute routers nats describe "public-nat-hub" \
    --router="nat-router-hub" --region="${REGION}" --project="${PROJECT_ID}" &>/dev/null; then
  gcloud compute routers nats delete "public-nat-hub" \
    --router="nat-router-hub" --region="${REGION}" --project="${PROJECT_ID}" --quiet
  echo "NAT gateway 'public-nat-hub' deleted."
fi

if resource_exists gcloud compute routers describe "nat-router-hub" \
    --region="${REGION}" --project="${PROJECT_ID}"; then
  gcloud compute routers delete "nat-router-hub" \
    --region="${REGION}" --project="${PROJECT_ID}" --quiet
  echo "Cloud Router 'nat-router-hub' deleted."
fi

# ============================================================
# Step 3: Delete hub VPN router (if no VPN tunnels remain)
# ============================================================
echo ""
echo "--- Step 3: Delete hub VPN router ---"
if resource_exists gcloud compute routers describe "vpn-router-hub" \
    --region="${REGION}" --project="${PROJECT_ID}"; then
  gcloud compute routers delete "vpn-router-hub" \
    --region="${REGION}" --project="${PROJECT_ID}" --quiet
  echo "Cloud Router 'vpn-router-hub' deleted."
fi

# ============================================================
# Step 4: Delete hub firewall rules
# ============================================================
echo ""
echo "--- Step 4: Delete hub firewall rules ---"
for fw in allow-iap-ssh-hub allow-nat-ingress-hub allow-internal-hub; do
  if resource_exists gcloud compute firewall-rules describe "${fw}" --project="${PROJECT_ID}"; then
    gcloud compute firewall-rules delete "${fw}" --project="${PROJECT_ID}" --quiet
    echo "Firewall rule '${fw}' deleted."
  else
    echo "Firewall rule '${fw}' does not exist, skipping."
  fi
done

# ============================================================
# Step 5: Delete hub subnet
# ============================================================
echo ""
echo "--- Step 5: Delete hub subnet ---"
if resource_exists gcloud compute networks subnets describe "compute-hub" \
    --region="${REGION}" --project="${PROJECT_ID}"; then
  gcloud compute networks subnets delete "compute-hub" \
    --region="${REGION}" --project="${PROJECT_ID}" --quiet
  echo "Subnet 'compute-hub' deleted."
else
  echo "Subnet 'compute-hub' does not exist, skipping."
fi

# ============================================================
# Step 6: Delete hub VPC
# ============================================================
echo ""
echo "--- Step 6: Delete hub VPC ---"
if resource_exists gcloud compute networks describe "hub" --project="${PROJECT_ID}"; then
  if gcloud compute networks delete "hub" --project="${PROJECT_ID}" --quiet 2>/dev/null; then
    echo "VPC 'hub' deleted."
  else
    echo "  WARNING: Could not delete VPC 'hub'."
    FAILED_RESOURCES+=("vpc/hub")
  fi
else
  echo "VPC 'hub' does not exist, skipping."
fi

# ============================================================
# Step 7: Delete Artifact Registry
# ============================================================
echo ""
echo "--- Step 7: Delete Artifact Registry repository ---"
if resource_exists gcloud artifacts repositories describe "${REPO_NAME}" \
    --location="${REGION}" --project="${PROJECT_ID}"; then
  gcloud artifacts repositories delete "${REPO_NAME}" \
    --location="${REGION}" --project="${PROJECT_ID}" --quiet
  echo "Repository '${REPO_NAME}' deleted."
else
  echo "Repository '${REPO_NAME}' does not exist, skipping."
fi

# ============================================================
# Step 8: Remove IAM bindings and delete service account
# ============================================================
echo ""
echo "--- Step 8: Remove IAM bindings ---"
if gcloud iam service-accounts describe "${SA_EMAIL}" --project="${PROJECT_ID}" &>/dev/null; then
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

echo ""
echo "--- Step 9: Delete service account ---"
if gcloud iam service-accounts describe "${SA_EMAIL}" --project="${PROJECT_ID}" &>/dev/null; then
  gcloud iam service-accounts delete "${SA_EMAIL}" --project="${PROJECT_ID}" --quiet
  echo "Service account '${SA_EMAIL}' deleted."
else
  echo "Service account '${SA_EMAIL}' does not exist, skipping."
fi

echo ""
if [[ ${#FAILED_RESOURCES[@]} -gt 0 ]]; then
  echo "=== Hub teardown complete (with warnings) ==="
  echo ""
  for res in "${FAILED_RESOURCES[@]}"; do
    echo "  - ${res}"
  done
else
  echo "=== Hub teardown complete ==="
fi

#!/usr/bin/env bash
#
# direct-vpc-egress/setup-infra.sh — Create spoke infrastructure for Direct VPC Egress approach (idempotent)
#
# Sets up shared hub (via shared/setup-hub.sh), then creates spoke VPCs,
# subnets (overlapping 240.0.0.0/20, routable, proxy-only, PNAT), firewall
# rules, Cloud Run services, and Cloud Run jobs.
#
# Run this as the service account created by setup-iam.sh:
#   gcloud config set auth/impersonate_service_account cloud-run-nat-poc@PROJECT.iam.gserviceaccount.com
#
# After this, run ./setup-connectivity.sh for VPN/NAT/ILB.
#
set -euo pipefail

# --- Configuration ---
PROJECT_ID="${PROJECT_ID:-sb-paul-g-vpcsac}"

REGION="europe-north2"
ZONE="${REGION}-a"
REPO_NAME="cloud-run-nat-poc"
SERVICE_IMAGE_NAME="http-server"
JOB_IMAGE_NAME="http-client"
IMAGE_TAG="latest"
SERVICE_IMAGE_URL="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO_NAME}/${SERVICE_IMAGE_NAME}:${IMAGE_TAG}"
JOB_IMAGE_URL="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO_NAME}/${JOB_IMAGE_NAME}:${IMAGE_TAG}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Setup Infrastructure (Direct VPC Egress) for project: ${PROJECT_ID} ==="
echo "Region: ${REGION}"
echo ""

# --- Helper ---
resource_exists() {
  "$@" &>/dev/null
  return $?
}

# ============================================================
# Step 1: Shared hub infrastructure
# ============================================================
echo "--- Step 1: Shared hub infrastructure ---"
"${SCRIPT_DIR}/../shared/setup-hub.sh"

# ============================================================
# Step 2: Create spoke VPC networks
# ============================================================
echo ""
echo "--- Step 2: Create spoke VPC networks ---"
for vpc in spoke-1 spoke-2; do
  if resource_exists gcloud compute networks describe "${vpc}" --project="${PROJECT_ID}"; then
    echo "VPC '${vpc}' already exists, skipping."
  else
    gcloud compute networks create "${vpc}" \
      --subnet-mode=custom \
      --project="${PROJECT_ID}"
    echo "VPC '${vpc}' created."
  fi
done

# ============================================================
# Step 3: Create spoke subnets
# ============================================================
echo ""
echo "--- Step 3: Create spoke subnets ---"
for spoke_num in 1 2; do
  spoke="spoke-${spoke_num}"

  # Overlapping Class E subnet (Cloud Run egress)
  subnet="overlap-${spoke}"
  if resource_exists gcloud compute networks subnets describe "${subnet}" \
      --region="${REGION}" --project="${PROJECT_ID}"; then
    echo "Subnet '${subnet}' already exists, skipping."
  else
    gcloud compute networks subnets create "${subnet}" \
      --network="${spoke}" \
      --range="240.0.0.0/20" \
      --region="${REGION}" \
      --project="${PROJECT_ID}"
    echo "Subnet '${subnet}' (240.0.0.0/20) created in ${spoke}."
  fi

  # Routable /22 (ILB forwarding rule)
  subnet="routable-${spoke}"
  cidr="10.${spoke_num}.0.0/22"
  if resource_exists gcloud compute networks subnets describe "${subnet}" \
      --region="${REGION}" --project="${PROJECT_ID}"; then
    echo "Subnet '${subnet}' already exists, skipping."
  else
    gcloud compute networks subnets create "${subnet}" \
      --network="${spoke}" \
      --range="${cidr}" \
      --region="${REGION}" \
      --project="${PROJECT_ID}"
    echo "Subnet '${subnet}' (${cidr}) created in ${spoke}."
  fi

  # Proxy-only subnet (ILB) — Class E, same across all spokes (never advertised via BGP)
  subnet="proxy-${spoke}"
  cidr="241.0.0.0/18"
  if resource_exists gcloud compute networks subnets describe "${subnet}" \
      --region="${REGION}" --project="${PROJECT_ID}"; then
    echo "Subnet '${subnet}' already exists, skipping."
  else
    gcloud compute networks subnets create "${subnet}" \
      --network="${spoke}" \
      --range="${cidr}" \
      --region="${REGION}" \
      --purpose=REGIONAL_MANAGED_PROXY \
      --role=ACTIVE \
      --project="${PROJECT_ID}"
    echo "Subnet '${subnet}' (${cidr}) created in ${spoke} (proxy-only)."
  fi

  # Private NAT subnet
  subnet="pnat-${spoke}"
  cidr="172.16.${spoke_num}.0/24"
  if resource_exists gcloud compute networks subnets describe "${subnet}" \
      --region="${REGION}" --project="${PROJECT_ID}"; then
    echo "Subnet '${subnet}' already exists, skipping."
  else
    gcloud compute networks subnets create "${subnet}" \
      --network="${spoke}" \
      --range="${cidr}" \
      --region="${REGION}" \
      --purpose=PRIVATE_NAT \
      --project="${PROJECT_ID}"
    echo "Subnet '${subnet}' (${cidr}) created in ${spoke} (private NAT)."
  fi
done

# ============================================================
# Step 4: Spoke firewall rules
# ============================================================
echo ""
echo "--- Step 4: Create spoke firewall rules ---"
for spoke_num in 1 2; do
  spoke="spoke-${spoke_num}"
  fw="allow-internal-${spoke}"
  if resource_exists gcloud compute firewall-rules describe "${fw}" --project="${PROJECT_ID}"; then
    echo "Firewall rule '${fw}' already exists, skipping."
  else
    gcloud compute firewall-rules create "${fw}" \
      --network="${spoke}" \
      --allow=tcp,udp,icmp \
      --source-ranges="10.0.0.0/8,172.16.0.0/16" \
      --direction=INGRESS \
      --project="${PROJECT_ID}"
    echo "Firewall rule '${fw}' created."
  fi
done

# ============================================================
# Step 5: Cloud Run services (one per spoke)
# ============================================================
echo ""
echo "--- Step 5: Deploy Cloud Run services ---"
for spoke_num in 1 2; do
  spoke="spoke-${spoke_num}"
  service="cr-${spoke}"
  subnet="overlap-${spoke}"

  if resource_exists gcloud run services describe "${service}" \
      --region="${REGION}" --project="${PROJECT_ID}"; then
    echo "Service '${service}' already exists, skipping."
  else
    echo "Deploying '${service}' -> ${spoke}/${subnet}..."
    gcloud run deploy "${service}" \
      --image="${SERVICE_IMAGE_URL}" \
      --region="${REGION}" \
      --network="${spoke}" \
      --subnet="${subnet}" \
      --vpc-egress=all-traffic \
      --ingress=internal \
      --max-instances=5 \
      --min-instances=0 \
      --cpu-throttling \
      --allow-unauthenticated \
      --project="${PROJECT_ID}" \
      --quiet
    echo "Service '${service}' deployed."
  fi
done

# ============================================================
# Step 6: Cloud Run jobs (one per spoke — test client)
# ============================================================
echo ""
echo "--- Step 6: Create Cloud Run jobs ---"

# Get VM IP for job target
VM_IP="$(gcloud compute instances describe "vm-hub" \
  --zone="${ZONE}" --project="${PROJECT_ID}" \
  --format='get(networkInterfaces[0].networkIP)' 2>/dev/null || true)"

if [[ -z "${VM_IP}" ]]; then
  echo "WARNING: Could not determine VM IP. Skipping job creation."
  echo "Run this script again after the VM is created."
else
  echo "VM IP: ${VM_IP}"
  for spoke_num in 1 2; do
    spoke="spoke-${spoke_num}"
    job="job-${spoke}"
    subnet="overlap-${spoke}"

    if gcloud run jobs describe "${job}" \
        --region="${REGION}" --project="${PROJECT_ID}" &>/dev/null; then
      echo "Job '${job}' already exists, skipping."
    else
      echo "Creating '${job}' -> ${spoke}/${subnet}..."
      gcloud run jobs create "${job}" \
        --image="${JOB_IMAGE_URL}" \
        --region="${REGION}" \
        --network="${spoke}" \
        --subnet="${subnet}" \
        --vpc-egress=all-traffic \
        --max-retries=0 \
        --task-timeout=60s \
        --set-env-vars="TARGET_URL=http://${VM_IP}" \
        --project="${PROJECT_ID}" \
        --quiet
      echo "Job '${job}' created."
    fi
  done
fi

# ============================================================
# Summary
# ============================================================
echo ""
echo "=== Infrastructure setup complete (Direct VPC Egress) ==="
echo ""
echo "Hub: VPC hub, subnet compute-hub (10.0.0.0/28), vm-hub"
echo "Spoke VPCs: spoke-1, spoke-2"
echo "Cloud Run services: cr-spoke-1, cr-spoke-2 (Direct VPC Egress on 240.0.0.0/20)"
echo "Cloud Run jobs: job-spoke-1, job-spoke-2"
echo ""
echo "Next: run ./setup-connectivity.sh to create VPN, NAT, and ILB."

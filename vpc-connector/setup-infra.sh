#!/usr/bin/env bash
#
# vpc-connector/setup-infra.sh — Create spoke infrastructure for VPC Connector approach (idempotent)
#
# Sets up shared hub (via shared/setup-hub.sh), then creates spoke VPCs,
# subnets (connector, routable, proxy-only), firewall rules, VPC Access
# Connectors, Cloud Run services, and Cloud Run jobs.
#
# Key difference from Direct VPC Egress:
#   - No overlapping 240.0.0.0/8 subnet (Cloud Run doesn't deploy into VPC)
#   - No PNAT subnet (no Hybrid NAT needed)
#   - VPC Access Connector handles the NAT boundary
#   - Cloud Run uses --vpc-connector instead of --network/--subnet
#
# Run this as the service account created by setup-iam.sh.
# After this, run ./setup-connectivity.sh for VPN and ILB.
#
set -euo pipefail

# --- Configuration ---
PROJECT_ID="${PROJECT_ID:-sb-paul-g-workshop}"

REGION="europe-north2"
ZONE="${REGION}-a"
REPO_NAME="cloud-run-nat-poc"
SERVICE_IMAGE_NAME="http-server"
JOB_IMAGE_NAME="http-client"
IMAGE_TAG="latest"
SERVICE_IMAGE_URL="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO_NAME}/${SERVICE_IMAGE_NAME}:${IMAGE_TAG}"
JOB_IMAGE_URL="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO_NAME}/${JOB_IMAGE_NAME}:${IMAGE_TAG}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Setup Infrastructure (VPC Connector) for project: ${PROJECT_ID} ==="
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
for vpc in spoke-c1 spoke-c2; do
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
  spoke="spoke-c${spoke_num}"

  # Connector subnet — unique /28 per spoke (Cloud Run traffic exits with these IPs)
  subnet="connector-${spoke}"
  cidr="10.10.${spoke_num}.0/28"
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

  # Routable /28 (ILB forwarding rule)
  subnet="routable-${spoke}"
  cidr="10.1${spoke_num}.0.0/28"
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

  # Proxy-only subnet (ILB) — overlapping is OK (internal to Envoy, never advertised)
  subnet="proxy-${spoke}"
  cidr="241.0.0.0/26"
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
done

# ============================================================
# Step 4: Spoke firewall rules
# ============================================================
echo ""
echo "--- Step 4: Create spoke firewall rules ---"
for spoke_num in 1 2; do
  spoke="spoke-c${spoke_num}"
  fw="allow-internal-${spoke}"
  if resource_exists gcloud compute firewall-rules describe "${fw}" --project="${PROJECT_ID}"; then
    echo "Firewall rule '${fw}' already exists, skipping."
  else
    # No 172.16.0.0/16 needed — connector IPs are already in 10.0.0.0/8
    gcloud compute firewall-rules create "${fw}" \
      --network="${spoke}" \
      --allow=tcp,udp,icmp \
      --source-ranges="10.0.0.0/8" \
      --direction=INGRESS \
      --project="${PROJECT_ID}"
    echo "Firewall rule '${fw}' created."
  fi
done

# ============================================================
# Step 5: VPC Access Connectors
# ============================================================
echo ""
echo "--- Step 5: Create VPC Access Connectors ---"
for spoke_num in 1 2; do
  spoke="spoke-c${spoke_num}"
  connector="connector-${spoke}"
  subnet="connector-${spoke}"

  if gcloud compute networks vpc-access connectors describe "${connector}" \
      --region="${REGION}" --project="${PROJECT_ID}" &>/dev/null; then
    echo "VPC Access Connector '${connector}' already exists, skipping."
  else
    echo "Creating VPC Access Connector '${connector}'..."
    gcloud compute networks vpc-access connectors create "${connector}" \
      --region="${REGION}" \
      --subnet="${subnet}" \
      --machine-type=e2-micro \
      --min-instances=2 \
      --max-instances=3 \
      --project="${PROJECT_ID}"
    echo "VPC Access Connector '${connector}' created."
  fi
done

# Wait for connectors to reach READY state
echo ""
echo "Waiting for connectors to reach READY state..."
for spoke_num in 1 2; do
  connector="connector-spoke-c${spoke_num}"
  for attempt in $(seq 1 30); do
    state="$(gcloud compute networks vpc-access connectors describe "${connector}" \
      --region="${REGION}" --project="${PROJECT_ID}" \
      --format='get(state)' 2>/dev/null || echo 'UNKNOWN')"
    if [[ "${state}" == "READY" ]]; then
      echo "  ${connector}: READY"
      break
    fi
    if [[ ${attempt} -eq 30 ]]; then
      echo "  WARNING: ${connector} not READY after 5 minutes (state: ${state})"
    else
      echo "  ${connector}: ${state} (waiting 10s...)"
      sleep 10
    fi
  done
done

# ============================================================
# Step 6: Cloud Run services (one per spoke)
# ============================================================
echo ""
echo "--- Step 6: Deploy Cloud Run services ---"
for spoke_num in 1 2; do
  spoke="spoke-c${spoke_num}"
  service="cr-${spoke}"
  connector="connector-${spoke}"

  if resource_exists gcloud run services describe "${service}" \
      --region="${REGION}" --project="${PROJECT_ID}"; then
    echo "Service '${service}' already exists, skipping."
  else
    echo "Deploying '${service}' with VPC Connector '${connector}'..."
    gcloud run deploy "${service}" \
      --image="${SERVICE_IMAGE_URL}" \
      --region="${REGION}" \
      --vpc-connector="${connector}" \
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
# Step 7: Cloud Run jobs (one per spoke — test client)
# ============================================================
echo ""
echo "--- Step 7: Create Cloud Run jobs ---"

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
    spoke="spoke-c${spoke_num}"
    job="job-${spoke}"
    connector="connector-${spoke}"

    if gcloud run jobs describe "${job}" \
        --region="${REGION}" --project="${PROJECT_ID}" &>/dev/null; then
      echo "Job '${job}' already exists, skipping."
    else
      echo "Creating '${job}' with VPC Connector '${connector}'..."
      gcloud run jobs create "${job}" \
        --image="${JOB_IMAGE_URL}" \
        --region="${REGION}" \
        --vpc-connector="${connector}" \
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
echo "=== Infrastructure setup complete (VPC Connector) ==="
echo ""
echo "Hub: VPC hub, subnet compute-hub (10.0.0.0/28), vm-hub"
echo "Spoke VPCs: spoke-c1, spoke-c2"
echo "VPC Connectors: connector-spoke-c1 (10.10.1.0/28), connector-spoke-c2 (10.10.2.0/28)"
echo "Cloud Run services: cr-spoke-c1, cr-spoke-c2 (via VPC Connector)"
echo "Cloud Run jobs: job-spoke-c1, job-spoke-c2"
echo ""
echo "Next: run ./setup-connectivity.sh to create VPN and ILB."

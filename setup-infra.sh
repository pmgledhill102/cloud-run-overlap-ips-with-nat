#!/usr/bin/env bash
#
# setup-infra.sh — Create base infrastructure (idempotent)
#
# Creates hub + spoke VPCs, subnets, firewall rules, Artifact Registry,
# container images, VM, and Cloud Run services/jobs.
#
# Run this as the service account created by setup-iam.sh:
#   gcloud config set auth/impersonate_service_account cloud-run-nat-poc@PROJECT.iam.gserviceaccount.com
#
# After this, run setup-connectivity.sh for VPN/NAT/ILB.
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

echo "=== Setup Infrastructure for project: ${PROJECT_ID} ==="
echo "Region: ${REGION}"
echo ""

# --- Helper ---
resource_exists() {
  "$@" &>/dev/null
  return $?
}

# ============================================================
# Step 1: Artifact Registry
# ============================================================
echo "--- Step 1: Artifact Registry ---"
if resource_exists gcloud artifacts repositories describe "${REPO_NAME}" \
    --location="${REGION}" --project="${PROJECT_ID}"; then
  echo "Repository '${REPO_NAME}' already exists, skipping."
else
  gcloud artifacts repositories create "${REPO_NAME}" \
    --repository-format=docker \
    --location="${REGION}" \
    --description="Cloud Run NAT PoC container images" \
    --project="${PROJECT_ID}"
  echo "Repository '${REPO_NAME}' created."
fi

# ============================================================
# Step 2: Build and push container images
# ============================================================
echo ""
echo "--- Step 2: Build and push container images ---"
gcloud auth configure-docker "${REGION}-docker.pkg.dev" --quiet 2>/dev/null || true

# Service image (http-server)
if gcloud artifacts docker images describe "${SERVICE_IMAGE_URL}" --project="${PROJECT_ID}" &>/dev/null; then
  echo "Image '${SERVICE_IMAGE_URL}' already exists, skipping build."
else
  echo "Building service image..."
  docker build --platform linux/amd64 -t "${SERVICE_IMAGE_URL}" "${SCRIPT_DIR}/container"
  docker push "${SERVICE_IMAGE_URL}"
  echo "Image pushed to ${SERVICE_IMAGE_URL}"
fi

# Job image (http-client)
if gcloud artifacts docker images describe "${JOB_IMAGE_URL}" --project="${PROJECT_ID}" &>/dev/null; then
  echo "Image '${JOB_IMAGE_URL}' already exists, skipping build."
else
  echo "Building job image..."
  docker build --platform linux/amd64 -t "${JOB_IMAGE_URL}" "${SCRIPT_DIR}/container-job"
  docker push "${JOB_IMAGE_URL}"
  echo "Image pushed to ${JOB_IMAGE_URL}"
fi

# ============================================================
# Step 3: Create VPC networks
# ============================================================
echo ""
echo "--- Step 3: Create VPC networks ---"
for vpc in hub spoke-1 spoke-2; do
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
# Step 4: Create subnets
# ============================================================
echo ""
echo "--- Step 4: Create subnets ---"

# Hub: compute subnet (VM lives here)
if resource_exists gcloud compute networks subnets describe "compute-hub" \
    --region="${REGION}" --project="${PROJECT_ID}"; then
  echo "Subnet 'compute-hub' already exists, skipping."
else
  gcloud compute networks subnets create "compute-hub" \
    --network=hub \
    --range="10.0.0.0/28" \
    --region="${REGION}" \
    --enable-private-ip-google-access \
    --project="${PROJECT_ID}"
  echo "Subnet 'compute-hub' (10.0.0.0/28) created in hub."
fi
# Ensure Private Google Access (idempotent)
gcloud compute networks subnets update "compute-hub" \
  --region="${REGION}" --enable-private-ip-google-access \
  --project="${PROJECT_ID}" --quiet

# Spoke subnets
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
      --range="240.0.0.0/8" \
      --region="${REGION}" \
      --project="${PROJECT_ID}"
    echo "Subnet '${subnet}' (240.0.0.0/8) created in ${spoke}."
  fi

  # Routable /28 (ILB forwarding rule)
  subnet="routable-${spoke}"
  cidr="10.${spoke_num}.0.0/28"
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

  # Proxy-only subnet (ILB)
  subnet="proxy-${spoke}"
  cidr="10.${spoke_num}.1.0/26"
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
# Step 5: Firewall rules
# ============================================================
echo ""
echo "--- Step 5: Create firewall rules ---"

# Hub: allow IAP SSH
if resource_exists gcloud compute firewall-rules describe "allow-iap-ssh-hub" --project="${PROJECT_ID}"; then
  echo "Firewall rule 'allow-iap-ssh-hub' already exists, skipping."
else
  gcloud compute firewall-rules create "allow-iap-ssh-hub" \
    --network=hub \
    --allow=tcp:22 \
    --source-ranges="35.235.240.0/20" \
    --direction=INGRESS \
    --project="${PROJECT_ID}"
  echo "Firewall rule 'allow-iap-ssh-hub' created."
fi

# Hub: allow NAT ingress (traffic from spokes via Hybrid NAT)
if resource_exists gcloud compute firewall-rules describe "allow-nat-ingress-hub" --project="${PROJECT_ID}"; then
  echo "Firewall rule 'allow-nat-ingress-hub' already exists, skipping."
else
  gcloud compute firewall-rules create "allow-nat-ingress-hub" \
    --network=hub \
    --allow=tcp,udp,icmp \
    --source-ranges="172.16.0.0/16" \
    --direction=INGRESS \
    --project="${PROJECT_ID}"
  echo "Firewall rule 'allow-nat-ingress-hub' created."
fi

# Hub: allow internal traffic
if resource_exists gcloud compute firewall-rules describe "allow-internal-hub" --project="${PROJECT_ID}"; then
  echo "Firewall rule 'allow-internal-hub' already exists, skipping."
else
  gcloud compute firewall-rules create "allow-internal-hub" \
    --network=hub \
    --allow=tcp,udp,icmp \
    --source-ranges="10.0.0.0/8" \
    --direction=INGRESS \
    --project="${PROJECT_ID}"
  echo "Firewall rule 'allow-internal-hub' created."
fi

# Spokes: allow internal + NAT traffic
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
# Step 6: Compute VM (hub)
# ============================================================
echo ""
echo "--- Step 6: Create Compute VM ---"
if resource_exists gcloud compute instances describe "vm-hub" \
    --zone="${ZONE}" --project="${PROJECT_ID}"; then
  echo "Instance 'vm-hub' already exists, skipping."
else
  gcloud compute instances create "vm-hub" \
    --zone="${ZONE}" \
    --machine-type=e2-micro \
    --network-interface=network=hub,subnet=compute-hub,no-address \
    --metadata=startup-script='#!/bin/bash
mkdir -p /var/www
cat > /var/www/index.html <<HTMLEOF
Hello from vm-hub ($(hostname))
HTMLEOF
cat > /etc/systemd/system/webserver.service <<UNIT
[Unit]
Description=Simple Python HTTP Server
After=network.target
[Service]
WorkingDirectory=/var/www
ExecStart=/usr/bin/python3 -m http.server 80
Restart=always
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now webserver' \
    --project="${PROJECT_ID}"
  echo "Instance 'vm-hub' created."
fi

# ============================================================
# Step 7: Cloud Run services (one per spoke)
# ============================================================
echo ""
echo "--- Step 7: Deploy Cloud Run services ---"
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
# Step 8: Cloud Run jobs (one per spoke — test client)
# ============================================================
echo ""
echo "--- Step 8: Create Cloud Run jobs ---"

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
echo "=== Infrastructure setup complete ==="
echo ""
echo "VPCs: hub, spoke-1, spoke-2"
echo "VM: vm-hub (hub/compute-hub, 10.0.0.0/28)"
echo "Cloud Run services: cr-spoke-1, cr-spoke-2"
echo "Cloud Run jobs: job-spoke-1, job-spoke-2"
echo ""
echo "Next: run ./setup-connectivity.sh to create VPN, NAT, and ILB."

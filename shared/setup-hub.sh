#!/usr/bin/env bash
#
# shared/setup-hub.sh — Create shared hub infrastructure (idempotent)
#
# Creates Artifact Registry, container images, hub VPC, subnets,
# firewall rules, and the hub VM. Shared by both approaches.
#
# Called by: direct-vpc-egress/setup-infra.sh, vpc-connector/setup-infra.sh
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
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "=== Setup Hub Infrastructure for project: ${PROJECT_ID} ==="
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
  docker build --platform linux/amd64 -t "${SERVICE_IMAGE_URL}" "${ROOT_DIR}/container"
  docker push "${SERVICE_IMAGE_URL}"
  echo "Image pushed to ${SERVICE_IMAGE_URL}"
fi

# Job image (http-client)
if gcloud artifacts docker images describe "${JOB_IMAGE_URL}" --project="${PROJECT_ID}" &>/dev/null; then
  echo "Image '${JOB_IMAGE_URL}' already exists, skipping build."
else
  echo "Building job image..."
  docker build --platform linux/amd64 -t "${JOB_IMAGE_URL}" "${ROOT_DIR}/container-job"
  docker push "${JOB_IMAGE_URL}"
  echo "Image pushed to ${JOB_IMAGE_URL}"
fi

# ============================================================
# Step 3: Create hub VPC network
# ============================================================
echo ""
echo "--- Step 3: Create hub VPC network ---"
if resource_exists gcloud compute networks describe "hub" --project="${PROJECT_ID}"; then
  echo "VPC 'hub' already exists, skipping."
else
  gcloud compute networks create "hub" \
    --subnet-mode=custom \
    --project="${PROJECT_ID}"
  echo "VPC 'hub' created."
fi

# ============================================================
# Step 4: Create hub subnet
# ============================================================
echo ""
echo "--- Step 4: Create hub subnet ---"
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

# ============================================================
# Step 5: Hub firewall rules
# ============================================================
echo ""
echo "--- Step 5: Create hub firewall rules ---"

# Allow IAP SSH
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

# Allow NAT ingress (traffic from spokes via Hybrid NAT or VPC Connector)
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

# Allow internal traffic (from spokes via VPN)
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

echo ""
echo "=== Hub infrastructure setup complete ==="
echo ""
echo "VPC: hub"
echo "Subnet: compute-hub (10.0.0.0/28)"
echo "VM: vm-hub (e2-micro, python3 HTTP server)"
echo "Images: ${SERVICE_IMAGE_URL}, ${JOB_IMAGE_URL}"

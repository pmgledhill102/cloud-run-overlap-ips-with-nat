#!/usr/bin/env bash
#
# setup-infra.sh — Create all infrastructure resources (idempotent)
#
# Run this as the service account created by setup-iam.sh, or impersonate it:
#   gcloud config set auth/impersonate_service_account cloud-run-nat-poc@PROJECT.iam.gserviceaccount.com
#
set -euo pipefail

# --- Configuration ---
PROJECT_ID="${PROJECT_ID:-sb-paul-g-workshop}"

REGION="europe-north2"
ZONE="${REGION}-a"
REPO_NAME="cloud-run-nat-poc"
IMAGE_NAME="sleep-server"
IMAGE_TAG="latest"
IMAGE_URL="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO_NAME}/${IMAGE_NAME}:${IMAGE_TAG}"
PROXY_IMAGE_NAME="proxy-server"
PROXY_IMAGE_URL="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO_NAME}/${PROXY_IMAGE_NAME}:${IMAGE_TAG}"
PROXY_SERVICE_NAME="cr-proxy-v2"
COMPUTE_INSTANCE_NAME="nat-poc-vm"
WEBSERVER_INSTANCE_NAME="nat-poc-webserver"
MAX_CONCURRENT_DEPLOYS=5

NUM_VPCS=2
NUM_SUBNETS_PER_VPC=3
NUM_SERVICES_PER_SUBNET=3

# Class E base octets for non-routable subnets
CLASS_E_BASES=(240 241 242)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Setup Infrastructure for project: ${PROJECT_ID} ==="
echo "Region: ${REGION}"
echo ""

# --- Helper functions ---
resource_exists() {
  "$@" &>/dev/null
  return $?
}

# --- Step 1: Artifact Registry ---
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

# --- Step 2: Build and push container image ---
echo ""
echo "--- Step 2: Build and push container image ---"
# Check if image already exists
if gcloud artifacts docker images describe "${IMAGE_URL}" --project="${PROJECT_ID}" &>/dev/null; then
  echo "Image '${IMAGE_URL}' already exists, skipping build."
else
  echo "Building container image..."
  gcloud auth configure-docker "${REGION}-docker.pkg.dev" --quiet 2>/dev/null || true

  docker build --platform linux/amd64 -t "${IMAGE_URL}" "${SCRIPT_DIR}/container"
  docker push "${IMAGE_URL}"
  echo "Image pushed to ${IMAGE_URL}"
fi

# Build proxy image
if gcloud artifacts docker images describe "${PROXY_IMAGE_URL}" --project="${PROJECT_ID}" &>/dev/null; then
  echo "Image '${PROXY_IMAGE_URL}' already exists, skipping build."
else
  echo "Building proxy container image..."
  gcloud auth configure-docker "${REGION}-docker.pkg.dev" --quiet 2>/dev/null || true

  docker build --platform linux/amd64 -t "${PROXY_IMAGE_URL}" "${SCRIPT_DIR}/container-proxy"
  docker push "${PROXY_IMAGE_URL}"
  echo "Image pushed to ${PROXY_IMAGE_URL}"
fi

# --- Step 3: Create VPC networks ---
echo ""
echo "--- Step 3: Create VPC networks ---"
for v in $(seq 1 ${NUM_VPCS}); do
  vpc_name="vpc-${v}"
  if resource_exists gcloud compute networks describe "${vpc_name}" --project="${PROJECT_ID}"; then
    echo "VPC '${vpc_name}' already exists, skipping."
  else
    gcloud compute networks create "${vpc_name}" \
      --subnet-mode=custom \
      --project="${PROJECT_ID}"
    echo "VPC '${vpc_name}' created."
  fi
done

# --- Step 4: Create subnets ---
echo ""
echo "--- Step 4: Create subnets ---"

# Class E subnets (non-routable, overlapping across all VPCs)
for v in $(seq 1 ${NUM_VPCS}); do
  vpc_name="vpc-${v}"
  for s in $(seq 0 $((NUM_SUBNETS_PER_VPC - 1))); do
    base="${CLASS_E_BASES[$s]}"
    subnet_name="class-e-${base}-vpc-${v}"
    cidr="${base}.0.0.0/8"

    if resource_exists gcloud compute networks subnets describe "${subnet_name}" \
        --region="${REGION}" --project="${PROJECT_ID}"; then
      echo "Subnet '${subnet_name}' already exists, skipping."
    else
      gcloud compute networks subnets create "${subnet_name}" \
        --network="${vpc_name}" \
        --range="${cidr}" \
        --region="${REGION}" \
        --project="${PROJECT_ID}"
      echo "Subnet '${subnet_name}' (${cidr}) created in ${vpc_name}."
    fi
  done
done

# Routable subnets (unique per VPC)
for v in $(seq 1 ${NUM_VPCS}); do
  vpc_name="vpc-${v}"
  subnet_name="routable-${v}"
  cidr="10.$((v - 1)).0.0/28"

  if resource_exists gcloud compute networks subnets describe "${subnet_name}" \
      --region="${REGION}" --project="${PROJECT_ID}"; then
    echo "Subnet '${subnet_name}' already exists, skipping."
  else
    gcloud compute networks subnets create "${subnet_name}" \
      --network="${vpc_name}" \
      --range="${cidr}" \
      --region="${REGION}" \
      --project="${PROJECT_ID}"
    echo "Subnet '${subnet_name}' (${cidr}) created in ${vpc_name}."
  fi
done

# Compute instance subnet in VPC-1
COMPUTE_SUBNET_NAME="compute-subnet"
COMPUTE_SUBNET_CIDR="10.${NUM_VPCS}.0.0/28"
COMPUTE_VPC="vpc-1"
if resource_exists gcloud compute networks subnets describe "${COMPUTE_SUBNET_NAME}" \
    --region="${REGION}" --project="${PROJECT_ID}"; then
  echo "Subnet '${COMPUTE_SUBNET_NAME}' already exists, skipping."
else
  gcloud compute networks subnets create "${COMPUTE_SUBNET_NAME}" \
    --network="${COMPUTE_VPC}" \
    --range="${COMPUTE_SUBNET_CIDR}" \
    --region="${REGION}" \
    --project="${PROJECT_ID}"
  echo "Subnet '${COMPUTE_SUBNET_NAME}' (${COMPUTE_SUBNET_CIDR}) created in ${COMPUTE_VPC}."
fi

# --- Step 5: Firewall rules ---
echo ""
echo "--- Step 5: Create firewall rules ---"

# Allow internal traffic within each VPC
for v in $(seq 1 ${NUM_VPCS}); do
  vpc_name="vpc-${v}"
  fw_name="allow-internal-${v}"

  if resource_exists gcloud compute firewall-rules describe "${fw_name}" --project="${PROJECT_ID}"; then
    echo "Firewall rule '${fw_name}' already exists, skipping."
  else
    gcloud compute firewall-rules create "${fw_name}" \
      --network="${vpc_name}" \
      --allow=tcp,udp,icmp \
      --source-ranges="10.0.0.0/8,240.0.0.0/4" \
      --direction=INGRESS \
      --project="${PROJECT_ID}"
    echo "Firewall rule '${fw_name}' created."
  fi
done

# Allow IAP SSH on VPC-1 (where compute instance lives)
FW_IAP="allow-iap-ssh-vpc-1"
if resource_exists gcloud compute firewall-rules describe "${FW_IAP}" --project="${PROJECT_ID}"; then
  echo "Firewall rule '${FW_IAP}' already exists, skipping."
else
  gcloud compute firewall-rules create "${FW_IAP}" \
    --network="${COMPUTE_VPC}" \
    --allow=tcp:22 \
    --source-ranges="35.235.240.0/20" \
    --direction=INGRESS \
    --project="${PROJECT_ID}"
  echo "Firewall rule '${FW_IAP}' created."
fi

# --- Step 6: Deploy Cloud Run services ---
echo ""
echo "--- Step 6: Deploy Cloud Run services (${NUM_VPCS} VPCs × ${NUM_SUBNETS_PER_VPC} subnets × ${NUM_SERVICES_PER_SUBNET} services = $((NUM_VPCS * NUM_SUBNETS_PER_VPC * NUM_SERVICES_PER_SUBNET)) total) ---"

deploy_count=0
running_jobs=0

for v in $(seq 1 ${NUM_VPCS}); do
  vpc_name="vpc-${v}"
  for s in $(seq 0 $((NUM_SUBNETS_PER_VPC - 1))); do
    base="${CLASS_E_BASES[$s]}"
    subnet_name="class-e-${base}-vpc-${v}"

    for i in $(seq 1 ${NUM_SERVICES_PER_SUBNET}); do
      service_name="cr-v${v}-s$((s + 1))-$(printf '%02d' ${i})"

      # Check if service already exists
      if resource_exists gcloud run services describe "${service_name}" \
          --region="${REGION}" --project="${PROJECT_ID}"; then
        echo "Service '${service_name}' already exists, skipping."
        continue
      fi

      echo "Deploying '${service_name}' -> ${vpc_name}/${subnet_name}..."
      gcloud run deploy "${service_name}" \
        --image="${IMAGE_URL}" \
        --region="${REGION}" \
        --network="${vpc_name}" \
        --subnet="${subnet_name}" \
        --vpc-egress=all-traffic \
        --ingress=internal \
        --max-instances=20 \
        --min-instances=0 \
        --cpu-throttling \
        --no-allow-unauthenticated \
        --project="${PROJECT_ID}" \
        --quiet &

      running_jobs=$((running_jobs + 1))
      deploy_count=$((deploy_count + 1))

      # Throttle: wait for one job to finish if at max concurrency
      if [[ ${running_jobs} -ge ${MAX_CONCURRENT_DEPLOYS} ]]; then
        wait -n
        running_jobs=$((running_jobs - 1))
      fi
    done
  done
done

# Wait for remaining deployments
wait
echo "Deployed ${deploy_count} new Cloud Run services."

# --- Step 7: Create Compute Instance ---
echo ""
echo "--- Step 7: Create Compute Instance ---"
if resource_exists gcloud compute instances describe "${COMPUTE_INSTANCE_NAME}" \
    --zone="${ZONE}" --project="${PROJECT_ID}"; then
  echo "Instance '${COMPUTE_INSTANCE_NAME}' already exists, skipping."
else
  gcloud compute instances create "${COMPUTE_INSTANCE_NAME}" \
    --zone="${ZONE}" \
    --machine-type=e2-micro \
    --network-interface=network=${COMPUTE_VPC},subnet=compute-subnet,no-address \
    --project="${PROJECT_ID}"
  echo "Instance '${COMPUTE_INSTANCE_NAME}' created."
fi

# --- Step 8: Create Webserver Instance ---
echo ""
echo "--- Step 8: Create Webserver Instance ---"
if resource_exists gcloud compute instances describe "${WEBSERVER_INSTANCE_NAME}" \
    --zone="${ZONE}" --project="${PROJECT_ID}"; then
  echo "Instance '${WEBSERVER_INSTANCE_NAME}' already exists, skipping."
else
  gcloud compute instances create "${WEBSERVER_INSTANCE_NAME}" \
    --zone="${ZONE}" \
    --machine-type=e2-micro \
    --network-interface=network=${COMPUTE_VPC},subnet=compute-subnet,no-address \
    --metadata=startup-script='#!/bin/bash
apt-get update -y
apt-get install -y nginx
systemctl enable nginx
systemctl start nginx' \
    --project="${PROJECT_ID}"
  echo "Instance '${WEBSERVER_INSTANCE_NAME}' created."
fi

# --- Step 9: Deploy proxy Cloud Run service ---
echo ""
echo "--- Step 9: Deploy proxy Cloud Run service ---"

# Get webserver private IP
WEBSERVER_IP="$(gcloud compute instances describe "${WEBSERVER_INSTANCE_NAME}" \
  --zone="${ZONE}" --project="${PROJECT_ID}" \
  --format='get(networkInterfaces[0].networkIP)' 2>/dev/null || true)"

if [[ -z "${WEBSERVER_IP}" ]]; then
  echo "WARNING: Could not determine webserver IP. Skipping proxy service deployment."
  echo "Run this script again after the webserver instance is created."
else
  echo "Webserver IP: ${WEBSERVER_IP}"

  if resource_exists gcloud run services describe "${PROXY_SERVICE_NAME}" \
      --region="${REGION}" --project="${PROJECT_ID}"; then
    echo "Service '${PROXY_SERVICE_NAME}' already exists, skipping."
  else
    echo "Deploying '${PROXY_SERVICE_NAME}' -> vpc-2/class-e-240-vpc-2..."
    gcloud run deploy "${PROXY_SERVICE_NAME}" \
      --image="${PROXY_IMAGE_URL}" \
      --region="${REGION}" \
      --network=vpc-2 \
      --subnet=class-e-240-vpc-2 \
      --vpc-egress=all-traffic \
      --ingress=internal \
      --max-instances=5 \
      --min-instances=0 \
      --cpu-throttling \
      --no-allow-unauthenticated \
      --set-env-vars="TARGET_URL=http://${WEBSERVER_IP}" \
      --project="${PROJECT_ID}" \
      --quiet
    echo "Service '${PROXY_SERVICE_NAME}' deployed."
  fi
fi

echo ""
echo "=== Infrastructure setup complete ==="
echo ""
echo "Cloud Run services: $((NUM_VPCS * NUM_SUBNETS_PER_VPC * NUM_SERVICES_PER_SUBNET))"
echo "VPC networks: ${NUM_VPCS}"
echo "Compute instance: ${COMPUTE_INSTANCE_NAME} (${COMPUTE_VPC}, ${COMPUTE_SUBNET_CIDR})"
echo ""
echo "SSH to compute instance:"
echo "  gcloud compute ssh ${COMPUTE_INSTANCE_NAME} --zone=${ZONE} --tunnel-through-iap --project=${PROJECT_ID}"

#!/usr/bin/env bash
#
# teardown.sh — Destroy all infrastructure (idempotent)
#
# Tears down Cloud Run first (to release VPC address reservations), then
# connectivity (ILB, NAT, VPN), then base infra (VM, subnets, VPCs,
# Artifact Registry) and finally the service account.
#
# Safe to re-run: skips resources that don't exist.
#
set -euo pipefail

PROJECT_ID="${PROJECT_ID:-sb-paul-g-workshop}"

REGION="europe-north2"
ZONE="${REGION}-a"
REPO_NAME="cloud-run-nat-poc"
SA_NAME="cloud-run-nat-poc"
SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

echo "=== Teardown Infrastructure for project: ${PROJECT_ID} ==="
echo ""

# --- Helper ---
resource_exists() {
  "$@" &>/dev/null
  return $?
}

# ============================================================
# Step 1: Delete Cloud Run services and jobs
# ============================================================
# Delete these FIRST — Direct VPC egress holds address reservations in the
# overlap subnets. Deleting early gives GCP time to release them before we
# attempt to delete the subnets.
echo "--- Step 1: Delete Cloud Run services and jobs ---"
for spoke_num in 1 2; do
  spoke="spoke-${spoke_num}"

  service="cr-${spoke}"
  if resource_exists gcloud run services describe "${service}" \
      --region="${REGION}" --project="${PROJECT_ID}"; then
    gcloud run services delete "${service}" \
      --region="${REGION}" --project="${PROJECT_ID}" --quiet
    echo "Service '${service}' deleted."
  fi

  job="job-${spoke}"
  if gcloud run jobs describe "${job}" \
      --region="${REGION}" --project="${PROJECT_ID}" &>/dev/null; then
    gcloud run jobs delete "${job}" \
      --region="${REGION}" --project="${PROJECT_ID}" --quiet
    echo "Job '${job}' deleted."
  fi
done

# ============================================================
# Step 2: Delete Compute VM
# ============================================================
echo ""
echo "--- Step 2: Delete Compute VM ---"
if resource_exists gcloud compute instances describe "vm-hub" \
    --zone="${ZONE}" --project="${PROJECT_ID}"; then
  gcloud compute instances delete "vm-hub" \
    --zone="${ZONE}" --project="${PROJECT_ID}" --quiet
  echo "Instance 'vm-hub' deleted."
else
  echo "Instance 'vm-hub' does not exist, skipping."
fi

# ============================================================
# Step 3: Delete ILB resources (per spoke)
# ============================================================
echo ""
echo "--- Step 3: Delete ILB resources ---"
for spoke_num in 1 2; do
  spoke="spoke-${spoke_num}"

  # Forwarding rule
  fr="ilb-${spoke}"
  if resource_exists gcloud compute forwarding-rules describe "${fr}" \
      --region="${REGION}" --project="${PROJECT_ID}"; then
    gcloud compute forwarding-rules delete "${fr}" \
      --region="${REGION}" --project="${PROJECT_ID}" --quiet
    echo "Forwarding rule '${fr}' deleted."
  fi

  # Target HTTP proxy
  proxy="proxy-${spoke}"
  if resource_exists gcloud compute target-http-proxies describe "${proxy}" \
      --region="${REGION}" --project="${PROJECT_ID}"; then
    gcloud compute target-http-proxies delete "${proxy}" \
      --region="${REGION}" --project="${PROJECT_ID}" --quiet
    echo "Target HTTP proxy '${proxy}' deleted."
  fi

  # URL map
  urlmap="urlmap-${spoke}"
  if resource_exists gcloud compute url-maps describe "${urlmap}" \
      --region="${REGION}" --project="${PROJECT_ID}"; then
    gcloud compute url-maps delete "${urlmap}" \
      --region="${REGION}" --project="${PROJECT_ID}" --quiet
    echo "URL map '${urlmap}' deleted."
  fi

  # Backend service
  bs="bs-${spoke}"
  if resource_exists gcloud compute backend-services describe "${bs}" \
      --region="${REGION}" --project="${PROJECT_ID}"; then
    gcloud compute backend-services delete "${bs}" \
      --region="${REGION}" --project="${PROJECT_ID}" --quiet
    echo "Backend service '${bs}' deleted."
  fi

  # Serverless NEG
  neg="neg-${spoke}"
  if resource_exists gcloud compute network-endpoint-groups describe "${neg}" \
      --region="${REGION}" --project="${PROJECT_ID}"; then
    gcloud compute network-endpoint-groups delete "${neg}" \
      --region="${REGION}" --project="${PROJECT_ID}" --quiet
    echo "NEG '${neg}' deleted."
  fi
done

# ============================================================
# Step 4: Delete NAT gateways and their routers
# ============================================================
echo ""
echo "--- Step 4: Delete NAT gateways ---"

# Spoke Hybrid NATs
for spoke_num in 1 2; do
  spoke="spoke-${spoke_num}"
  nat_router="nat-router-${spoke}"
  nat_gw="hybrid-nat-${spoke}"

  if gcloud compute routers nats describe "${nat_gw}" \
      --router="${nat_router}" --region="${REGION}" --project="${PROJECT_ID}" &>/dev/null; then
    gcloud compute routers nats delete "${nat_gw}" \
      --router="${nat_router}" --region="${REGION}" --project="${PROJECT_ID}" --quiet
    echo "NAT gateway '${nat_gw}' deleted."
  fi

  if resource_exists gcloud compute routers describe "${nat_router}" \
      --region="${REGION}" --project="${PROJECT_ID}"; then
    gcloud compute routers delete "${nat_router}" \
      --region="${REGION}" --project="${PROJECT_ID}" --quiet
    echo "Cloud Router '${nat_router}' deleted."
  fi
done

# Hub Public NAT
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
# Step 5: Delete VPN tunnels
# ============================================================
echo ""
echo "--- Step 5: Delete VPN tunnels ---"
for spoke_num in 1 2; do
  spoke="spoke-${spoke_num}"
  for iface in 0 1; do
    for tunnel in "vpn-tunnel-hub-to-${spoke}-if${iface}" "vpn-tunnel-${spoke}-to-hub-if${iface}"; do
      if resource_exists gcloud compute vpn-tunnels describe "${tunnel}" \
          --region="${REGION}" --project="${PROJECT_ID}"; then
        gcloud compute vpn-tunnels delete "${tunnel}" \
          --region="${REGION}" --project="${PROJECT_ID}" --quiet
        echo "VPN tunnel '${tunnel}' deleted."
      fi
    done
  done
done

# ============================================================
# Step 6: Delete VPN gateways
# ============================================================
echo ""
echo "--- Step 6: Delete VPN gateways ---"
for gw in vpn-gw-hub-to-spoke-1 vpn-gw-hub-to-spoke-2 vpn-gw-spoke-1 vpn-gw-spoke-2; do
  if resource_exists gcloud compute vpn-gateways describe "${gw}" \
      --region="${REGION}" --project="${PROJECT_ID}"; then
    gcloud compute vpn-gateways delete "${gw}" \
      --region="${REGION}" --project="${PROJECT_ID}" --quiet
    echo "VPN gateway '${gw}' deleted."
  fi
done

# ============================================================
# Step 7: Delete VPN Cloud Routers
# ============================================================
echo ""
echo "--- Step 7: Delete VPN Cloud Routers ---"
for router in vpn-router-hub vpn-router-spoke-1 vpn-router-spoke-2; do
  if resource_exists gcloud compute routers describe "${router}" \
      --region="${REGION}" --project="${PROJECT_ID}"; then
    gcloud compute routers delete "${router}" \
      --region="${REGION}" --project="${PROJECT_ID}" --quiet
    echo "Cloud Router '${router}' deleted."
  fi
done

# ============================================================
# Step 8: Delete firewall rules
# ============================================================
echo ""
echo "--- Step 8: Delete firewall rules ---"
for fw in allow-iap-ssh-hub allow-nat-ingress-hub allow-internal-hub \
          allow-internal-spoke-1 allow-internal-spoke-2; do
  if resource_exists gcloud compute firewall-rules describe "${fw}" --project="${PROJECT_ID}"; then
    gcloud compute firewall-rules delete "${fw}" --project="${PROJECT_ID}" --quiet
    echo "Firewall rule '${fw}' deleted."
  else
    echo "Firewall rule '${fw}' does not exist, skipping."
  fi
done

# ============================================================
# Step 9: Delete subnets
# ============================================================
# Cloud Run Direct VPC egress address reservations can take a few minutes to
# release after the service is deleted. Retry with backoff if still in use.
echo ""
echo "--- Step 9: Delete subnets ---"
SUBNETS=(
  compute-hub
  overlap-spoke-1 overlap-spoke-2
  routable-spoke-1 routable-spoke-2
  proxy-spoke-1 proxy-spoke-2
  pnat-spoke-1 pnat-spoke-2
)

delete_subnet_with_retry() {
  local subnet="$1"
  local max_attempts=6
  local wait_secs=10

  for attempt in $(seq 1 "${max_attempts}"); do
    if gcloud compute networks subnets delete "${subnet}" \
        --region="${REGION}" --project="${PROJECT_ID}" --quiet 2>/dev/null; then
      echo "Subnet '${subnet}' deleted."
      return 0
    fi

    if [[ ${attempt} -lt ${max_attempts} ]]; then
      echo "  Subnet '${subnet}' still in use, retrying in ${wait_secs}s... (attempt ${attempt}/${max_attempts})"
      sleep "${wait_secs}"
      wait_secs=$((wait_secs * 2))
    else
      echo "  ERROR: Could not delete subnet '${subnet}' after ${max_attempts} attempts."
      return 1
    fi
  done
}

for subnet in "${SUBNETS[@]}"; do
  if resource_exists gcloud compute networks subnets describe "${subnet}" \
      --region="${REGION}" --project="${PROJECT_ID}"; then
    delete_subnet_with_retry "${subnet}"
  else
    echo "Subnet '${subnet}' does not exist, skipping."
  fi
done

# ============================================================
# Step 10: Delete VPC networks
# ============================================================
echo ""
echo "--- Step 10: Delete VPC networks ---"
for vpc in hub spoke-1 spoke-2; do
  if resource_exists gcloud compute networks describe "${vpc}" --project="${PROJECT_ID}"; then
    gcloud compute networks delete "${vpc}" --project="${PROJECT_ID}" --quiet
    echo "VPC '${vpc}' deleted."
  else
    echo "VPC '${vpc}' does not exist, skipping."
  fi
done

# ============================================================
# Step 11: Delete Artifact Registry
# ============================================================
echo ""
echo "--- Step 11: Delete Artifact Registry repository ---"
if resource_exists gcloud artifacts repositories describe "${REPO_NAME}" \
    --location="${REGION}" --project="${PROJECT_ID}"; then
  gcloud artifacts repositories delete "${REPO_NAME}" \
    --location="${REGION}" --project="${PROJECT_ID}" --quiet
  echo "Repository '${REPO_NAME}' deleted."
else
  echo "Repository '${REPO_NAME}' does not exist, skipping."
fi

# ============================================================
# Step 12: Remove IAM bindings and delete service account
# ============================================================
echo ""
echo "--- Step 12: Remove IAM bindings ---"
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
echo "--- Step 13: Delete service account ---"
if gcloud iam service-accounts describe "${SA_EMAIL}" --project="${PROJECT_ID}" &>/dev/null; then
  gcloud iam service-accounts delete "${SA_EMAIL}" --project="${PROJECT_ID}" --quiet
  echo "Service account '${SA_EMAIL}' deleted."
else
  echo "Service account '${SA_EMAIL}' does not exist, skipping."
fi

echo ""
echo "=== Teardown complete ==="

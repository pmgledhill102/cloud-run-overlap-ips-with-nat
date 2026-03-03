#!/usr/bin/env bash
#
# direct-vpc-egress/teardown.sh — Destroy Direct VPC Egress spoke infrastructure (idempotent)
#
# Tears down spoke-specific resources (Cloud Run, ILB, NAT, VPN, subnets, VPCs),
# then optionally tears down shared hub infrastructure.
#
# Safe to re-run: skips resources that don't exist.
#
set -euo pipefail

PROJECT_ID="${PROJECT_ID:-sb-paul-g-workshop}"

REGION="europe-north2"
ZONE="${REGION}-a"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Teardown (Direct VPC Egress) for project: ${PROJECT_ID} ==="
echo ""

# --- Helpers ---
resource_exists() {
  "$@" &>/dev/null
  return $?
}

FAILED_RESOURCES=()

# ============================================================
# Step 1: Delete Cloud Run services and jobs
# ============================================================
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
# Step 2: Delete ILB resources (per spoke)
# ============================================================
echo ""
echo "--- Step 2: Delete ILB resources ---"
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

  # Target HTTPS proxy
  proxy="proxy-${spoke}"
  if resource_exists gcloud compute target-https-proxies describe "${proxy}" \
      --region="${REGION}" --project="${PROJECT_ID}"; then
    gcloud compute target-https-proxies delete "${proxy}" \
      --region="${REGION}" --project="${PROJECT_ID}" --quiet
    echo "Target HTTPS proxy '${proxy}' deleted."
  fi

  # SSL certificate
  cert="ssl-${spoke}"
  if resource_exists gcloud compute ssl-certificates describe "${cert}" \
      --region="${REGION}" --project="${PROJECT_ID}"; then
    gcloud compute ssl-certificates delete "${cert}" \
      --region="${REGION}" --project="${PROJECT_ID}" --quiet
    echo "SSL certificate '${cert}' deleted."
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
# Step 3: Delete NAT gateways and their routers
# ============================================================
echo ""
echo "--- Step 3: Delete NAT gateways ---"
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

# ============================================================
# Step 4: Delete VPN tunnels
# ============================================================
echo ""
echo "--- Step 4: Delete VPN tunnels ---"
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
# Step 5: Delete VPN gateways
# ============================================================
echo ""
echo "--- Step 5: Delete VPN gateways ---"
for gw in vpn-gw-hub-to-spoke-1 vpn-gw-hub-to-spoke-2 vpn-gw-spoke-1 vpn-gw-spoke-2; do
  if resource_exists gcloud compute vpn-gateways describe "${gw}" \
      --region="${REGION}" --project="${PROJECT_ID}"; then
    gcloud compute vpn-gateways delete "${gw}" \
      --region="${REGION}" --project="${PROJECT_ID}" --quiet
    echo "VPN gateway '${gw}' deleted."
  fi
done

# ============================================================
# Step 6: Delete VPN Cloud Routers (spoke-side only; hub router handled by shared teardown)
# ============================================================
echo ""
echo "--- Step 6: Delete spoke VPN Cloud Routers ---"
for router in vpn-router-spoke-1 vpn-router-spoke-2; do
  if resource_exists gcloud compute routers describe "${router}" \
      --region="${REGION}" --project="${PROJECT_ID}"; then
    gcloud compute routers delete "${router}" \
      --region="${REGION}" --project="${PROJECT_ID}" --quiet
    echo "Cloud Router '${router}' deleted."
  fi
done

# ============================================================
# Step 7: Delete spoke firewall rules
# ============================================================
echo ""
echo "--- Step 7: Delete spoke firewall rules ---"
for fw in allow-internal-spoke-1 allow-internal-spoke-2; do
  if resource_exists gcloud compute firewall-rules describe "${fw}" --project="${PROJECT_ID}"; then
    gcloud compute firewall-rules delete "${fw}" --project="${PROJECT_ID}" --quiet
    echo "Firewall rule '${fw}' deleted."
  else
    echo "Firewall rule '${fw}' does not exist, skipping."
  fi
done

# ============================================================
# Step 8: Delete spoke subnets
# ============================================================
echo ""
echo "--- Step 8: Delete spoke subnets ---"
SUBNETS=(
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
      echo "  WARNING: Could not delete subnet '${subnet}' — still in use."
      FAILED_RESOURCES+=("subnet/${subnet}")
      return 0
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
# Step 9: Delete spoke VPC networks
# ============================================================
echo ""
echo "--- Step 9: Delete spoke VPC networks ---"
for vpc in spoke-1 spoke-2; do
  if resource_exists gcloud compute networks describe "${vpc}" --project="${PROJECT_ID}"; then
    if gcloud compute networks delete "${vpc}" --project="${PROJECT_ID}" --quiet 2>/dev/null; then
      echo "VPC '${vpc}' deleted."
    else
      echo "  WARNING: Could not delete VPC '${vpc}' — subnets may still be releasing."
      FAILED_RESOURCES+=("vpc/${vpc}")
    fi
  else
    echo "VPC '${vpc}' does not exist, skipping."
  fi
done

# ============================================================
# Step 10: Shared hub teardown
# ============================================================
echo ""
echo "--- Step 10: Shared hub teardown ---"
"${SCRIPT_DIR}/../shared/teardown-hub.sh"

echo ""
if [[ ${#FAILED_RESOURCES[@]} -gt 0 ]]; then
  echo "=== Teardown complete (with warnings) ==="
  echo ""
  echo "The following resources could not be deleted (Cloud Run may still be"
  echo "releasing VPC address reservations). Re-run this script later:"
  echo ""
  for res in "${FAILED_RESOURCES[@]}"; do
    echo "  - ${res}"
  done
else
  echo "=== Teardown complete ==="
fi

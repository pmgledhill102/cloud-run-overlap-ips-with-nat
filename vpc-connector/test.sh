#!/usr/bin/env bash
#
# vpc-connector/test.sh — Test both traffic flows (VPC Connector approach)
#
# Flow A (spoke→hub): Trigger Cloud Run Jobs that call VM via VPC Connector + VPN
# Flow B (hub→spoke): SSH to VM and curl ILB endpoints for Cloud Run services
#
# Prerequisites: setup-infra.sh and setup-connectivity.sh completed,
# BGP converged (~60s after setup-connectivity.sh).
#
set -euo pipefail

PROJECT_ID="${PROJECT_ID:-sb-paul-g-workshop}"

REGION="europe-north2"
ZONE="${REGION}-a"

echo "=== Testing Traffic Flows (VPC Connector) ==="
echo "Project: ${PROJECT_ID}"
echo ""

# ============================================================
# Flow A: Spoke → Hub (via VPC Connector + HA VPN — NO Hybrid NAT)
# ============================================================
echo "=========================================="
echo "  Flow A: Spoke → Hub (VPC Connector)"
echo "=========================================="
echo ""
echo "Cloud Run Job → VPC Connector VM (10.10.x.x) → HA VPN → VM (10.0.0.x)"
echo "(No Hybrid NAT needed — connector IPs are already unique and routable)"
echo ""

for spoke_num in 1 2; do
  job="job-spoke-c${spoke_num}"
  echo "--- Executing ${job} ---"
  gcloud run jobs execute "${job}" \
    --region="${REGION}" \
    --project="${PROJECT_ID}" \
    --wait 2>&1 || echo "  FAILED: ${job}"
  echo ""
done

# ============================================================
# Flow B: Hub → Spoke (via HA VPN + ILB)
# ============================================================
echo "=========================================="
echo "  Flow B: Hub → Spoke (ILB)"
echo "=========================================="
echo ""
echo "VM (10.0.0.x) → HA VPN → ILB (10.1x.0.x) → serverless NEG → Cloud Run service"
echo ""

# Get ILB IPs
for spoke_num in 1 2; do
  fr="ilb-spoke-c${spoke_num}"
  ip="$(gcloud compute forwarding-rules describe "${fr}" \
    --region="${REGION}" --project="${PROJECT_ID}" \
    --format='get(IPAddress)' 2>/dev/null || true)"

  if [[ -z "${ip}" ]]; then
    echo "ERROR: Could not get IP for ${fr}. Is setup-connectivity.sh complete?"
    continue
  fi

  echo "--- Curling ${fr} (${ip}) from vm-hub ---"
  gcloud compute ssh "vm-hub" \
    --zone="${ZONE}" \
    --tunnel-through-iap \
    --project="${PROJECT_ID}" \
    --command="curl -sk --max-time 10 https://${ip}/" 2>&1 || echo "  FAILED: curl ${ip}"
  echo ""
done

echo "=== Test complete ==="

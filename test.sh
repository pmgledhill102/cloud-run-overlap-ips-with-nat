#!/usr/bin/env bash
#
# test.sh — Test both traffic flows
#
# Flow A (spoke→hub): Trigger Cloud Run Jobs that call VM via Hybrid NAT + VPN
# Flow B (hub→spoke): SSH to VM and curl ILB endpoints for Cloud Run services
#
# Prerequisites: setup-infra.sh and setup-connectivity.sh completed,
# BGP converged (~60s after setup-connectivity.sh).
#
set -euo pipefail

PROJECT_ID="${PROJECT_ID:-sb-paul-g-workshop}"

REGION="europe-north2"
ZONE="${REGION}-a"

echo "=== Testing Traffic Flows ==="
echo "Project: ${PROJECT_ID}"
echo ""

# ============================================================
# Flow A: Spoke → Hub (via Hybrid NAT + HA VPN)
# ============================================================
echo "=========================================="
echo "  Flow A: Spoke → Hub (Hybrid NAT)"
echo "=========================================="
echo ""
echo "Cloud Run Job (240.x.x.x) → Hybrid NAT (→172.16.x.x) → HA VPN → VM (10.0.0.x)"
echo ""

for spoke_num in 1 2; do
  job="job-spoke-${spoke_num}"
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
echo "VM (10.0.0.x) → HA VPN → ILB (10.x.0.x) → serverless NEG → Cloud Run service"
echo ""

# Get ILB IPs
for spoke_num in 1 2; do
  fr="ilb-spoke-${spoke_num}"
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
    --command="curl -s --max-time 10 http://${ip}/" 2>&1 || echo "  FAILED: curl ${ip}"
  echo ""
done

echo "=== Test complete ==="

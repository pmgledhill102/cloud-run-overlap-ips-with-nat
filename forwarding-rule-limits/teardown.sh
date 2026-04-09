#!/usr/bin/env bash
#
# forwarding-rule-limits/teardown.sh — Destroy all forwarding rule limit test resources (idempotent)
#
# Deletes in reverse dependency order, each layer in parallel:
#   1. Forwarding rules
#   2. Target HTTP proxies
#   3. URL maps
#   4. Backend services
#   5. Serverless NEGs
#   6. Cloud Run service
#   7. Subnets
#   8. VPC network
#
# Safe to re-run: skips resources that don't exist.
#
set -euo pipefail

# --- Configuration ---
PROJECT_ID="${PROJECT_ID:-sb-paul-g-gastown-vide}"
REGION="europe-north2"
LB_COUNT="${LB_COUNT:-100}"
PARALLEL="${PARALLEL:-10}"

VPC_NAME="frl-test"
SUBNET_NAME="frl-routable"
PROXY_SUBNET_NAME="frl-proxy-only"
CR_SERVICE_NAME="frl-hello"

echo "=== Teardown Forwarding Rule Limits Test for project: ${PROJECT_ID} ==="
echo "Parallelism: ${PARALLEL}"
echo ""

# --- Helpers ---
resource_exists() {
  "$@" &>/dev/null
  return $?
}

# Delete a resource type in parallel across all 100 indices
# Usage: delete_parallel "resource type label" delete_command [args...]
# The placeholder {} in args is replaced with the zero-padded index
delete_parallel() {
  local label="$1"
  shift

  echo "--- ${label} ---"
  local active_pids=()
  local deleted=0

  for i in $(seq 1 "${LB_COUNT}"); do
    idx=$(printf "%03d" "${i}")

    # Build the command by replacing {} with the index
    local cmd=()
    for arg in "$@"; do
      cmd+=("${arg//\{\}/${idx}}")
    done

    (
      # Check existence with describe (first 3 args after gcloud compute ... describe)
      if "${cmd[@]}" --quiet 2>/dev/null; then
        echo "  Deleted ${cmd[3]}"
      fi
    ) &
    active_pids+=($!)

    if [ ${#active_pids[@]} -ge "${PARALLEL}" ]; then
      wait -n 2>/dev/null || true
      new_pids=()
      for pid in "${active_pids[@]}"; do
        if kill -0 "${pid}" 2>/dev/null; then
          new_pids+=("${pid}")
        fi
      done
      active_pids=("${new_pids[@]}")
    fi
  done

  wait
  echo ""
}

# ============================================================
# Step 1: Delete forwarding rules
# ============================================================
delete_parallel "Step 1: Delete forwarding rules" \
  gcloud compute forwarding-rules delete "frl-fr-{}" \
  --region="${REGION}" --project="${PROJECT_ID}"

# ============================================================
# Step 2: Delete target HTTP proxies
# ============================================================
delete_parallel "Step 2: Delete target HTTP proxies" \
  gcloud compute target-http-proxies delete "frl-proxy-{}" \
  --region="${REGION}" --project="${PROJECT_ID}"

# ============================================================
# Step 3: Delete URL maps
# ============================================================
delete_parallel "Step 3: Delete URL maps" \
  gcloud compute url-maps delete "frl-urlmap-{}" \
  --region="${REGION}" --project="${PROJECT_ID}"

# ============================================================
# Step 4: Delete backend services
# ============================================================
delete_parallel "Step 4: Delete backend services" \
  gcloud compute backend-services delete "frl-bs-{}" \
  --region="${REGION}" --project="${PROJECT_ID}"

# ============================================================
# Step 5: Delete serverless NEGs
# ============================================================
delete_parallel "Step 5: Delete serverless NEGs" \
  gcloud compute network-endpoint-groups delete "frl-neg-{}" \
  --region="${REGION}" --project="${PROJECT_ID}"

# ============================================================
# Step 6: Delete Cloud Run service
# ============================================================
echo "--- Step 6: Delete Cloud Run service ---"
if resource_exists gcloud run services describe "${CR_SERVICE_NAME}" \
    --region="${REGION}" --project="${PROJECT_ID}"; then
  gcloud run services delete "${CR_SERVICE_NAME}" \
    --region="${REGION}" --project="${PROJECT_ID}" --quiet
  echo "Cloud Run service '${CR_SERVICE_NAME}' deleted."
fi

# ============================================================
# Step 7: Delete subnets
# ============================================================
echo ""
echo "--- Step 7: Delete subnets ---"
for subnet in "${PROXY_SUBNET_NAME}" "${SUBNET_NAME}"; do
  if resource_exists gcloud compute networks subnets describe "${subnet}" \
      --region="${REGION}" --project="${PROJECT_ID}"; then
    gcloud compute networks subnets delete "${subnet}" \
      --region="${REGION}" --project="${PROJECT_ID}" --quiet
    echo "Subnet '${subnet}' deleted."
  fi
done

# ============================================================
# Step 8: Delete VPC network
# ============================================================
echo ""
echo "--- Step 8: Delete VPC network ---"
if resource_exists gcloud compute networks describe "${VPC_NAME}" \
    --project="${PROJECT_ID}"; then
  gcloud compute networks delete "${VPC_NAME}" \
    --project="${PROJECT_ID}" --quiet
  echo "VPC '${VPC_NAME}' deleted."
fi

echo ""
echo "=== Teardown complete ==="

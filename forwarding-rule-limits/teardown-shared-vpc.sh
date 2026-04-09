#!/usr/bin/env bash
#
# forwarding-rule-limits/teardown-shared-vpc.sh — Tear down Shared VPC forwarding rule test
#
# Deletes in reverse dependency order:
#   1. Forwarding rules (5 per LB × 10 LBs × 4 projects)
#   2. Target HTTP proxies
#   3. URL maps
#   4. Backend services
#   5. Serverless NEGs
#   6. Cloud Run services (unless --lb-only)
#   7. Disassociate service projects (unless --lb-only)
#   8. Subnets + VPC in host project (unless --lb-only)
#
# Usage:
#   ./teardown-shared-vpc.sh              # Full teardown
#   ./teardown-shared-vpc.sh --lb-only    # Only remove LB resources (steps 1-5)
#
# Safe to re-run: skips resources that don't exist.
#
set -euo pipefail

# --- Parse flags ---
LB_ONLY=false
for arg in "$@"; do
  case "${arg}" in
    --lb-only) LB_ONLY=true ;;
  esac
done

# --- Configuration ---
HOST_PROJECT="${HOST_PROJECT:-sb-paul-g-gastown-vide}"
SERVICE_PROJECTS="${SERVICE_PROJECTS:-sb-paul-g-load-1 sb-paul-g-load-2 sb-paul-g-load-3 sb-paul-g-load-4}"
REGION="europe-north2"
LB_PER_PROJECT="${LB_PER_PROJECT:-10}"
FR_PER_LB="${FR_PER_LB:-5}"
PARALLEL="${PARALLEL:-10}"

VPC_NAME="frl-shared"
SUBNET_NAME="frl-shared-routable"
PROXY_SUBNET_NAME="frl-shared-proxy-only"
CR_SERVICE_NAME="frl-hello"

read -ra SVC_PROJECTS <<< "${SERVICE_PROJECTS}"

echo "=== Teardown Shared VPC Forwarding Rule Limits Test ==="
echo "Host project:     ${HOST_PROJECT}"
echo "Service projects: ${SVC_PROJECTS[*]}"
echo "Mode:             $(if [ "${LB_ONLY}" = true ]; then echo "LB-only"; else echo "full"; fi)"
echo "Parallelism:      ${PARALLEL}"
echo ""

# --- Helpers ---
resource_exists() {
  "$@" &>/dev/null
  return $?
}

# Parallel job pool helper
wait_for_slot() {
  if [ ${#active_pids[@]} -ge "${PARALLEL}" ]; then
    wait -n 2>/dev/null || true
    local new_pids=()
    for pid in "${active_pids[@]}"; do
      if kill -0 "${pid}" 2>/dev/null; then
        new_pids+=("${pid}")
      fi
    done
    active_pids=("${new_pids[@]}")
  fi
}

# ============================================================
# Step 0: Delete old-format resources (frl-*-{svc_short}-{001..050})
# ============================================================
echo "--- Step 0: Clean up old-format resources ---"
OLD_COUNT=50
active_pids=()
for svc in "${SVC_PROJECTS[@]}"; do
  svc_short="${svc##*-}"
  for i in $(seq 1 "${OLD_COUNT}"); do
    idx=$(printf "%03d" "${i}")
    (
      for args in \
        "forwarding-rules frl-fr-${svc_short}-${idx}" \
        "target-http-proxies frl-px-${svc_short}-${idx}" \
        "url-maps frl-um-${svc_short}-${idx}" \
        "backend-services frl-bs-${svc_short}-${idx}" \
        "network-endpoint-groups frl-neg-${svc_short}-${idx}"; do
        set -- ${args}
        rtype="$1"; name="$2"
        if gcloud compute "${rtype}" describe "${name}" \
            --region="${REGION}" --project="${svc}" &>/dev/null; then
          gcloud compute "${rtype}" delete "${name}" \
            --region="${REGION}" --project="${svc}" --quiet 2>/dev/null
          echo "  Deleted ${name}"
        fi
      done
    ) &
    active_pids+=($!)
    wait_for_slot
  done
done
wait
echo ""

# ============================================================
# Step 1: Delete forwarding rules
# ============================================================
echo "--- Step 1: Delete forwarding rules ---"
active_pids=()
for svc in "${SVC_PROJECTS[@]}"; do
  svc_short="${svc##*-}"
  for lb in $(seq 1 "${LB_PER_PROJECT}"); do
    lb_idx=$(printf "%02d" "${lb}")
    for fr in $(seq 1 "${FR_PER_LB}"); do
      fr_idx=$(printf "%02d" "${fr}")
      name="frl-fr-${svc_short}-${lb_idx}-${fr_idx}"
      (
        if gcloud compute forwarding-rules describe "${name}" \
            --region="${REGION}" --project="${svc}" &>/dev/null; then
          gcloud compute forwarding-rules delete "${name}" \
            --region="${REGION}" --project="${svc}" --quiet 2>/dev/null
          echo "  Deleted ${name}"
        fi
      ) &
      active_pids+=($!)
      wait_for_slot
    done
  done
done
wait
echo ""

# ============================================================
# Step 2: Delete target HTTP proxies
# ============================================================
echo "--- Step 2: Delete target HTTP proxies ---"
active_pids=()
for svc in "${SVC_PROJECTS[@]}"; do
  svc_short="${svc##*-}"
  for lb in $(seq 1 "${LB_PER_PROJECT}"); do
    lb_idx=$(printf "%02d" "${lb}")
    name="frl-px-${svc_short}-${lb_idx}"
    (
      if gcloud compute target-http-proxies describe "${name}" \
          --region="${REGION}" --project="${svc}" &>/dev/null; then
        gcloud compute target-http-proxies delete "${name}" \
          --region="${REGION}" --project="${svc}" --quiet 2>/dev/null
        echo "  Deleted ${name}"
      fi
    ) &
    active_pids+=($!)
    wait_for_slot
  done
done
wait
echo ""

# ============================================================
# Step 3: Delete URL maps
# ============================================================
echo "--- Step 3: Delete URL maps ---"
active_pids=()
for svc in "${SVC_PROJECTS[@]}"; do
  svc_short="${svc##*-}"
  for lb in $(seq 1 "${LB_PER_PROJECT}"); do
    lb_idx=$(printf "%02d" "${lb}")
    name="frl-um-${svc_short}-${lb_idx}"
    (
      if gcloud compute url-maps describe "${name}" \
          --region="${REGION}" --project="${svc}" &>/dev/null; then
        gcloud compute url-maps delete "${name}" \
          --region="${REGION}" --project="${svc}" --quiet 2>/dev/null
        echo "  Deleted ${name}"
      fi
    ) &
    active_pids+=($!)
    wait_for_slot
  done
done
wait
echo ""

# ============================================================
# Step 4: Delete backend services
# ============================================================
echo "--- Step 4: Delete backend services ---"
active_pids=()
for svc in "${SVC_PROJECTS[@]}"; do
  svc_short="${svc##*-}"
  for lb in $(seq 1 "${LB_PER_PROJECT}"); do
    lb_idx=$(printf "%02d" "${lb}")
    name="frl-bs-${svc_short}-${lb_idx}"
    (
      if gcloud compute backend-services describe "${name}" \
          --region="${REGION}" --project="${svc}" &>/dev/null; then
        gcloud compute backend-services delete "${name}" \
          --region="${REGION}" --project="${svc}" --quiet 2>/dev/null
        echo "  Deleted ${name}"
      fi
    ) &
    active_pids+=($!)
    wait_for_slot
  done
done
wait
echo ""

# ============================================================
# Step 5: Delete serverless NEGs
# ============================================================
echo "--- Step 5: Delete serverless NEGs ---"
active_pids=()
for svc in "${SVC_PROJECTS[@]}"; do
  svc_short="${svc##*-}"
  for lb in $(seq 1 "${LB_PER_PROJECT}"); do
    lb_idx=$(printf "%02d" "${lb}")
    name="frl-neg-${svc_short}-${lb_idx}"
    (
      if gcloud compute network-endpoint-groups describe "${name}" \
          --region="${REGION}" --project="${svc}" &>/dev/null; then
        gcloud compute network-endpoint-groups delete "${name}" \
          --region="${REGION}" --project="${svc}" --quiet 2>/dev/null
        echo "  Deleted ${name}"
      fi
    ) &
    active_pids+=($!)
    wait_for_slot
  done
done
wait
echo ""

if [ "${LB_ONLY}" = true ]; then
  echo ""
  echo "=== LB-only teardown complete (Cloud Run, VPC, subnets retained) ==="
  exit 0
fi

# ============================================================
# Step 6: Delete Cloud Run services
# ============================================================
echo "--- Step 6: Delete Cloud Run services ---"
for svc in "${SVC_PROJECTS[@]}"; do
  if resource_exists gcloud run services describe "${CR_SERVICE_NAME}" \
      --region="${REGION}" --project="${svc}"; then
    gcloud run services delete "${CR_SERVICE_NAME}" \
      --region="${REGION}" --project="${svc}" --quiet
    echo "Cloud Run service deleted in '${svc}'."
  fi
done

# ============================================================
# Step 7: Disassociate service projects
# ============================================================
echo ""
echo "--- Step 7: Disassociate service projects ---"
for svc in "${SVC_PROJECTS[@]}"; do
  if gcloud compute shared-vpc associated-projects list "${HOST_PROJECT}" \
      --format="value(id)" 2>/dev/null | grep -q "^${svc}$"; then
    gcloud compute shared-vpc associated-projects remove "${svc}" \
      --host-project="${HOST_PROJECT}"
    echo "Disassociated '${svc}'."
  fi
done

# ============================================================
# Step 8: Delete subnets
# ============================================================
echo ""
echo "--- Step 8: Delete subnets ---"
for subnet in "${PROXY_SUBNET_NAME}" "${SUBNET_NAME}"; do
  if resource_exists gcloud compute networks subnets describe "${subnet}" \
      --region="${REGION}" --project="${HOST_PROJECT}"; then
    gcloud compute networks subnets delete "${subnet}" \
      --region="${REGION}" --project="${HOST_PROJECT}" --quiet
    echo "Subnet '${subnet}' deleted."
  fi
done

# ============================================================
# Step 9: Delete VPC network
# ============================================================
echo ""
echo "--- Step 9: Delete VPC network ---"
if resource_exists gcloud compute networks describe "${VPC_NAME}" \
    --project="${HOST_PROJECT}"; then
  gcloud compute networks delete "${VPC_NAME}" \
    --project="${HOST_PROJECT}" --quiet
  echo "VPC '${VPC_NAME}' deleted."
fi

echo ""
echo "=== Full teardown complete ==="

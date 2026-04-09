#!/usr/bin/env bash
#
# forwarding-rule-limits/setup.sh — Create 100 Regional Application LBs in a single VPC
#
# Investigates GCP forwarding rule limits by creating 100 Regional Application
# Load Balancers, each with its own forwarding rule, all pointing to the same
# Cloud Run service via serverless NEGs.
#
# Resources created per LB (x100):
#   - Serverless NEG → Cloud Run service
#   - Regional backend service
#   - Regional URL map
#   - Regional target HTTP proxy
#   - Regional forwarding rule
#
# Shared resources (x1):
#   - VPC network + proxy-only subnet + routable subnet
#   - Cloud Run service (hello container)
#
# Uses HTTP (not HTTPS) to avoid needing 100 SSL certificates.
#
# Usage:
#   ./setup.sh                  # Uses defaults (100 LBs, 10 parallel)
#   PROJECT_ID=my-project ./setup.sh
#   LB_COUNT=50 ./setup.sh      # Create fewer LBs
#   PARALLEL=5 ./setup.sh       # Adjust parallelism
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
SUBNET_RANGE="10.100.0.0/22"
PROXY_SUBNET_RANGE="10.200.0.0/18"
CR_SERVICE_NAME="frl-hello"
CR_IMAGE="us-docker.pkg.dev/cloudrun/container/hello"

echo "=== Forwarding Rule Limits Test for project: ${PROJECT_ID} ==="
echo "Region: ${REGION}"
echo "Target LB count: ${LB_COUNT}"
echo "Parallelism: ${PARALLEL}"
echo ""

# --- Helper ---
resource_exists() {
  "$@" &>/dev/null
  return $?
}

# ============================================================
# Step 1: VPC network
# ============================================================
echo "--- Step 1: VPC network ---"
if resource_exists gcloud compute networks describe "${VPC_NAME}" \
    --project="${PROJECT_ID}"; then
  echo "VPC '${VPC_NAME}' already exists, skipping."
else
  gcloud compute networks create "${VPC_NAME}" \
    --subnet-mode=custom \
    --project="${PROJECT_ID}"
  echo "VPC '${VPC_NAME}' created."
fi

# ============================================================
# Step 2: Subnets
# ============================================================
echo ""
echo "--- Step 2: Subnets ---"

# Routable subnet (for forwarding rules)
if resource_exists gcloud compute networks subnets describe "${SUBNET_NAME}" \
    --region="${REGION}" --project="${PROJECT_ID}"; then
  echo "Subnet '${SUBNET_NAME}' already exists, skipping."
else
  gcloud compute networks subnets create "${SUBNET_NAME}" \
    --network="${VPC_NAME}" \
    --region="${REGION}" \
    --range="${SUBNET_RANGE}" \
    --project="${PROJECT_ID}"
  echo "Subnet '${SUBNET_NAME}' (${SUBNET_RANGE}) created."
fi

# Proxy-only subnet (required for regional Application LBs)
if resource_exists gcloud compute networks subnets describe "${PROXY_SUBNET_NAME}" \
    --region="${REGION}" --project="${PROJECT_ID}"; then
  echo "Proxy-only subnet '${PROXY_SUBNET_NAME}' already exists, skipping."
else
  gcloud compute networks subnets create "${PROXY_SUBNET_NAME}" \
    --network="${VPC_NAME}" \
    --region="${REGION}" \
    --range="${PROXY_SUBNET_RANGE}" \
    --purpose=REGIONAL_MANAGED_PROXY \
    --role=ACTIVE \
    --project="${PROJECT_ID}"
  echo "Proxy-only subnet '${PROXY_SUBNET_NAME}' (${PROXY_SUBNET_RANGE}) created."
fi

# ============================================================
# Step 3: Cloud Run service
# ============================================================
echo ""
echo "--- Step 3: Cloud Run service ---"
if resource_exists gcloud run services describe "${CR_SERVICE_NAME}" \
    --region="${REGION}" --project="${PROJECT_ID}"; then
  echo "Cloud Run service '${CR_SERVICE_NAME}' already exists, skipping."
else
  gcloud run deploy "${CR_SERVICE_NAME}" \
    --image="${CR_IMAGE}" \
    --region="${REGION}" \
    --allow-unauthenticated \
    --ingress=internal \
    --project="${PROJECT_ID}" \
    --quiet
  echo "Cloud Run service '${CR_SERVICE_NAME}' deployed."
fi

# ============================================================
# Step 4: Create Regional Application LBs (parallel)
# ============================================================
echo ""
echo "--- Step 4: Create ${LB_COUNT} Regional Application LBs (${PARALLEL} parallel) ---"

RESULTS_DIR="$(mktemp -d)"

cleanup() { rm -rf "${RESULTS_DIR}"; }
trap cleanup EXIT

create_lb() {
  # Disable parent's EXIT trap in subshell so it doesn't nuke the temp dir
  trap - EXIT
  local i="$1"
  local idx
  idx=$(printf "%03d" "${i}")
  local neg="frl-neg-${idx}"
  local bs="frl-bs-${idx}"
  local urlmap="frl-urlmap-${idx}"
  local proxy="frl-proxy-${idx}"
  local fr="frl-fr-${idx}"
  local logfile="${RESULTS_DIR}/${idx}.log"
  local status="created"

  {
    echo "[${i}/${LB_COUNT}] Creating LB ${idx}..."

    # Serverless NEG
    if gcloud compute network-endpoint-groups describe "${neg}" \
        --region="${REGION}" --project="${PROJECT_ID}" &>/dev/null; then
      echo "  NEG '${neg}' exists."
    else
      if ! gcloud compute network-endpoint-groups create "${neg}" \
          --region="${REGION}" \
          --network-endpoint-type=serverless \
          --cloud-run-service="${CR_SERVICE_NAME}" \
          --project="${PROJECT_ID}" 2>&1; then
        echo "  FAILED: NEG '${neg}'"
        status="failed"
      fi
    fi

    # Backend service
    if [ "${status}" != "failed" ]; then
      if gcloud compute backend-services describe "${bs}" \
          --region="${REGION}" --project="${PROJECT_ID}" &>/dev/null; then
        echo "  Backend service '${bs}' exists."
      else
        if ! gcloud compute backend-services create "${bs}" \
            --region="${REGION}" \
            --load-balancing-scheme=INTERNAL_MANAGED \
            --protocol=HTTP \
            --project="${PROJECT_ID}" 2>&1; then
          echo "  FAILED: Backend service '${bs}'"
          status="failed"
        else
          gcloud compute backend-services add-backend "${bs}" \
            --region="${REGION}" \
            --network-endpoint-group="${neg}" \
            --network-endpoint-group-region="${REGION}" \
            --project="${PROJECT_ID}" 2>&1 || true
        fi
      fi
    fi

    # URL map
    if [ "${status}" != "failed" ]; then
      if gcloud compute url-maps describe "${urlmap}" \
          --region="${REGION}" --project="${PROJECT_ID}" &>/dev/null; then
        echo "  URL map '${urlmap}' exists."
      else
        if ! gcloud compute url-maps create "${urlmap}" \
            --region="${REGION}" \
            --default-service="${bs}" \
            --project="${PROJECT_ID}" 2>&1; then
          echo "  FAILED: URL map '${urlmap}'"
          status="failed"
        fi
      fi
    fi

    # Target HTTP proxy
    if [ "${status}" != "failed" ]; then
      if gcloud compute target-http-proxies describe "${proxy}" \
          --region="${REGION}" --project="${PROJECT_ID}" &>/dev/null; then
        echo "  Target HTTP proxy '${proxy}' exists."
      else
        if ! gcloud compute target-http-proxies create "${proxy}" \
            --url-map="${urlmap}" \
            --region="${REGION}" \
            --project="${PROJECT_ID}" 2>&1; then
          echo "  FAILED: Target HTTP proxy '${proxy}'"
          status="failed"
        fi
      fi
    fi

    # Forwarding rule
    if [ "${status}" != "failed" ]; then
      if gcloud compute forwarding-rules describe "${fr}" \
          --region="${REGION}" --project="${PROJECT_ID}" &>/dev/null; then
        echo "  Forwarding rule '${fr}' exists."
        status="skipped"
      else
        if ! gcloud compute forwarding-rules create "${fr}" \
            --region="${REGION}" \
            --load-balancing-scheme=INTERNAL_MANAGED \
            --network="${VPC_NAME}" \
            --subnet="${SUBNET_NAME}" \
            --target-http-proxy="${proxy}" \
            --target-http-proxy-region="${REGION}" \
            --ports=80 \
            --project="${PROJECT_ID}" 2>&1; then
          echo "  FAILED: Forwarding rule '${fr}' (may have hit limit)"
          status="failed"
        fi
      fi
    fi

    echo "  => ${status}"
  } > "${logfile}" 2>&1

  echo "${status}" > "${RESULTS_DIR}/${idx}.status"
}

# Launch LBs in parallel, capped at $PARALLEL concurrent jobs
active_pids=()
for i in $(seq 1 "${LB_COUNT}"); do
  create_lb "${i}" &
  active_pids+=($!)

  # When we hit the parallel limit, wait for one to finish before continuing
  if [ ${#active_pids[@]} -ge "${PARALLEL}" ]; then
    wait -n 2>/dev/null || true
    # Clean up finished PIDs
    new_pids=()
    for pid in "${active_pids[@]}"; do
      if kill -0 "${pid}" 2>/dev/null; then
        new_pids+=("${pid}")
      fi
    done
    active_pids=("${new_pids[@]}")
  fi
done

# Wait for all remaining jobs
wait

# Print logs in order
for i in $(seq 1 "${LB_COUNT}"); do
  idx=$(printf "%03d" "${i}")
  logfile="${RESULTS_DIR}/${idx}.log"
  if [ -f "${logfile}" ]; then
    cat "${logfile}"
  fi
done

# ============================================================
# Summary
# ============================================================
created=0
skipped=0
failed=0
for i in $(seq 1 "${LB_COUNT}"); do
  idx=$(printf "%03d" "${i}")
  statusfile="${RESULTS_DIR}/${idx}.status"
  if [ -f "${statusfile}" ]; then
    s="$(cat "${statusfile}")"
    case "${s}" in
      created) created=$((created + 1)) ;;
      skipped) skipped=$((skipped + 1)) ;;
      failed)  failed=$((failed + 1)) ;;
    esac
  else
    failed=$((failed + 1))
  fi
done

echo ""
echo "=== Summary ==="
echo "Created: ${created}"
echo "Skipped (already existed): ${skipped}"
echo "Failed: ${failed}"
echo ""

echo "--- Forwarding rules in project ---"
total_fr="$(gcloud compute forwarding-rules list \
  --project="${PROJECT_ID}" \
  --format="value(name)" | wc -l | tr -d ' ')"
echo "Total forwarding rules in project: ${total_fr}"

regional_fr="$(gcloud compute forwarding-rules list \
  --filter="region:${REGION}" \
  --project="${PROJECT_ID}" \
  --format="value(name)" | wc -l | tr -d ' ')"
echo "Total forwarding rules in ${REGION}: ${regional_fr}"

echo ""
echo "=== Next steps ==="
echo "Run ./teardown.sh to clean up all resources."

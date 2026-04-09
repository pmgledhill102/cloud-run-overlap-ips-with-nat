#!/usr/bin/env bash
#
# forwarding-rule-limits/setup-shared-vpc.sh — Test forwarding rule limits across Shared VPC
#
# Creates a Shared VPC host with 4 service projects, each creating forwarding
# rules on the shared network. Tests whether the per-project-per-region limit
# (observed: 50) applies per service project independently, allowing 4 × 50 = 200
# forwarding rules on a single VPC network.
#
# Structure per service project:
#   - 10 LB stacks (NEG + backend service + URL map + target HTTP proxy)
#   - 5 forwarding rules per LB stack (all sharing the same proxy)
#   = 50 forwarding rules per project
#   × 4 projects = 200 total
#
# This stays within the 10 URL maps per project quota.
#
# Prerequisites:
#   - 5 GCP projects (1 host + 4 service)
#   - Org-level Shared VPC admin role (roles/compute.xpnAdmin) on the caller
#   - All projects in the same org
#   - Compute Engine API enabled in all projects
#   - Cloud Run API enabled in all service projects
#
# Usage:
#   ./setup-shared-vpc.sh                  # Full: 10 LBs × 5 FRs = 50/project = 200 total
#   ./setup-shared-vpc.sh --minimal        # Minimal: 2 LBs × 2 FRs = 4/project = 16 total
#   HOST_PROJECT=my-host ./setup-shared-vpc.sh
#   PARALLEL=5 ./setup-shared-vpc.sh
#
set -euo pipefail

# --- Parse flags ---
MINIMAL=false
for arg in "$@"; do
  case "${arg}" in
    --minimal) MINIMAL=true ;;
  esac
done

# --- Configuration ---
HOST_PROJECT="${HOST_PROJECT:-sb-paul-g-gastown-vide}"
SERVICE_PROJECTS="${SERVICE_PROJECTS:-sb-paul-g-load-1 sb-paul-g-load-2 sb-paul-g-load-3 sb-paul-g-load-4}"
REGION="europe-north2"
if [ "${MINIMAL}" = true ]; then
  LB_PER_PROJECT="${LB_PER_PROJECT:-2}"
  FR_PER_LB="${FR_PER_LB:-2}"
else
  LB_PER_PROJECT="${LB_PER_PROJECT:-10}"
  FR_PER_LB="${FR_PER_LB:-5}"
fi
PARALLEL="${PARALLEL:-10}"

VPC_NAME="frl-shared"
SUBNET_NAME="frl-shared-routable"
PROXY_SUBNET_NAME="frl-shared-proxy-only"
SUBNET_RANGE="10.101.0.0/22"
PROXY_SUBNET_RANGE="10.201.0.0/18"
CR_SERVICE_NAME="frl-hello"
CR_IMAGE="us-docker.pkg.dev/cloudrun/container/hello"

# Convert space-separated string to array
read -ra SVC_PROJECTS <<< "${SERVICE_PROJECTS}"

FRL_PER_PROJECT=$((LB_PER_PROJECT * FR_PER_LB))
TOTAL_FRL=$((FRL_PER_PROJECT * ${#SVC_PROJECTS[@]}))

echo "=== Shared VPC Forwarding Rule Limits Test ==="
echo "Host project:     ${HOST_PROJECT}"
echo "Service projects: ${SVC_PROJECTS[*]}"
echo "Region:           ${REGION}"
echo "LBs per project:  ${LB_PER_PROJECT} (URL maps, proxies, etc.)"
echo "FRs per LB:       ${FR_PER_LB}"
echo "FRs per project:  ${FRL_PER_PROJECT}"
echo "Target total FRs: ${TOTAL_FRL}"
echo "Parallelism:      ${PARALLEL}"
echo ""

# --- Helper ---
resource_exists() {
  "$@" &>/dev/null
  return $?
}

# ============================================================
# Step 1: Enable Shared VPC on host project
# ============================================================
echo "--- Step 1: Enable Shared VPC on host project ---"
if gcloud compute shared-vpc get-host-project "${HOST_PROJECT}" --project="${HOST_PROJECT}" &>/dev/null; then
  echo "Shared VPC already enabled on '${HOST_PROJECT}'."
else
  gcloud compute shared-vpc enable "${HOST_PROJECT}"
  echo "Shared VPC enabled on '${HOST_PROJECT}'."
fi

# ============================================================
# Step 2: VPC network + subnets (in host project)
# ============================================================
echo ""
echo "--- Step 2: VPC network + subnets (host project) ---"

if resource_exists gcloud compute networks describe "${VPC_NAME}" \
    --project="${HOST_PROJECT}"; then
  echo "VPC '${VPC_NAME}' already exists, skipping."
else
  gcloud compute networks create "${VPC_NAME}" \
    --subnet-mode=custom \
    --project="${HOST_PROJECT}"
  echo "VPC '${VPC_NAME}' created."
fi

# Routable subnet
if resource_exists gcloud compute networks subnets describe "${SUBNET_NAME}" \
    --region="${REGION}" --project="${HOST_PROJECT}"; then
  echo "Subnet '${SUBNET_NAME}' already exists, skipping."
else
  gcloud compute networks subnets create "${SUBNET_NAME}" \
    --network="${VPC_NAME}" \
    --region="${REGION}" \
    --range="${SUBNET_RANGE}" \
    --project="${HOST_PROJECT}"
  echo "Subnet '${SUBNET_NAME}' (${SUBNET_RANGE}) created."
fi

# Proxy-only subnet
if resource_exists gcloud compute networks subnets describe "${PROXY_SUBNET_NAME}" \
    --region="${REGION}" --project="${HOST_PROJECT}"; then
  echo "Proxy-only subnet '${PROXY_SUBNET_NAME}' already exists, skipping."
else
  gcloud compute networks subnets create "${PROXY_SUBNET_NAME}" \
    --network="${VPC_NAME}" \
    --region="${REGION}" \
    --range="${PROXY_SUBNET_RANGE}" \
    --purpose=REGIONAL_MANAGED_PROXY \
    --role=ACTIVE \
    --project="${HOST_PROJECT}"
  echo "Proxy-only subnet '${PROXY_SUBNET_NAME}' (${PROXY_SUBNET_RANGE}) created."
fi

# ============================================================
# Step 3: Associate service projects with host
# ============================================================
echo ""
echo "--- Step 3: Associate service projects ---"
for svc in "${SVC_PROJECTS[@]}"; do
  if gcloud compute shared-vpc associated-projects list "${HOST_PROJECT}" \
      --format="value(id)" 2>/dev/null | grep -q "^${svc}$"; then
    echo "Service project '${svc}' already associated."
  else
    gcloud compute shared-vpc associated-projects add "${svc}" \
      --host-project="${HOST_PROJECT}"
    echo "Service project '${svc}' associated with host."
  fi
done

# ============================================================
# Step 4: Grant subnet access to service projects
# ============================================================
echo ""
echo "--- Step 4: Grant subnet access to service projects ---"
for svc in "${SVC_PROJECTS[@]}"; do
  # Get the project number for the service project
  svc_number="$(gcloud projects describe "${svc}" --format='value(projectNumber)')"

  # Grant networkUser on the routable subnet to the project's default compute SA
  # and Cloud Run service agent
  for member in \
    "serviceAccount:${svc_number}-compute@developer.gserviceaccount.com" \
    "serviceAccount:service-${svc_number}@serverless-robot-prod.iam.gserviceaccount.com"; do

    gcloud compute networks subnets add-iam-policy-binding "${SUBNET_NAME}" \
      --region="${REGION}" \
      --project="${HOST_PROJECT}" \
      --member="${member}" \
      --role="roles/compute.networkUser" \
      --condition=None \
      --quiet 2>/dev/null || true
  done
  echo "Granted subnet access to '${svc}'."
done

# ============================================================
# Step 5: Enable APIs in service projects
# ============================================================
echo ""
echo "--- Step 5: Enable APIs in service projects ---"
for svc in "${SVC_PROJECTS[@]}"; do
  gcloud services enable run.googleapis.com compute.googleapis.com \
    --project="${svc}" --quiet 2>/dev/null || true
  echo "APIs enabled in '${svc}'."
done

# ============================================================
# Step 6: Deploy Cloud Run service in each service project
# ============================================================
echo ""
echo "--- Step 6: Deploy Cloud Run service in each service project ---"
for svc in "${SVC_PROJECTS[@]}"; do
  if resource_exists gcloud run services describe "${CR_SERVICE_NAME}" \
      --region="${REGION}" --project="${svc}"; then
    echo "Cloud Run service '${CR_SERVICE_NAME}' already exists in '${svc}', skipping."
  else
    gcloud run deploy "${CR_SERVICE_NAME}" \
      --image="${CR_IMAGE}" \
      --region="${REGION}" \
      --allow-unauthenticated \
      --ingress=internal \
      --project="${svc}" \
      --quiet
    echo "Cloud Run service '${CR_SERVICE_NAME}' deployed in '${svc}'."
  fi
done

# ============================================================
# Step 7a: Create LB stacks (10 per service project, parallel)
# ============================================================
echo ""
echo "--- Step 7a: Create ${LB_PER_PROJECT} LB stacks per service project (${PARALLEL} parallel) ---"

RESULTS_DIR="$(mktemp -d)"

cleanup() { rm -rf "${RESULTS_DIR}"; }
trap cleanup EXIT

create_lb_stack() {
  trap - EXIT
  local svc="$1"
  local lb_num="$2"
  local lb_idx
  lb_idx=$(printf "%02d" "${lb_num}")
  local svc_short="${svc##*-}"
  local neg="frl-neg-${svc_short}-${lb_idx}"
  local bs="frl-bs-${svc_short}-${lb_idx}"
  local urlmap="frl-um-${svc_short}-${lb_idx}"
  local proxy="frl-px-${svc_short}-${lb_idx}"
  local logfile="${RESULTS_DIR}/stack-${svc_short}-${lb_idx}.log"
  local status="created"

  {
    echo "[${svc_short} LB ${lb_num}/${LB_PER_PROJECT}] Creating stack..."

    # Serverless NEG
    if gcloud compute network-endpoint-groups describe "${neg}" \
        --region="${REGION}" --project="${svc}" &>/dev/null; then
      echo "  NEG exists."
    else
      if ! gcloud compute network-endpoint-groups create "${neg}" \
          --region="${REGION}" \
          --network-endpoint-type=serverless \
          --cloud-run-service="${CR_SERVICE_NAME}" \
          --project="${svc}" 2>&1; then
        echo "  FAILED: NEG"
        status="failed"
      fi
    fi

    # Backend service
    if [ "${status}" != "failed" ]; then
      if gcloud compute backend-services describe "${bs}" \
          --region="${REGION}" --project="${svc}" &>/dev/null; then
        echo "  Backend service exists."
      else
        if ! gcloud compute backend-services create "${bs}" \
            --region="${REGION}" \
            --load-balancing-scheme=INTERNAL_MANAGED \
            --protocol=HTTP \
            --project="${svc}" 2>&1; then
          echo "  FAILED: Backend service"
          status="failed"
        else
          gcloud compute backend-services add-backend "${bs}" \
            --region="${REGION}" \
            --network-endpoint-group="${neg}" \
            --network-endpoint-group-region="${REGION}" \
            --project="${svc}" 2>&1 || true
        fi
      fi
    fi

    # URL map
    if [ "${status}" != "failed" ]; then
      if gcloud compute url-maps describe "${urlmap}" \
          --region="${REGION}" --project="${svc}" &>/dev/null; then
        echo "  URL map exists."
      else
        if ! gcloud compute url-maps create "${urlmap}" \
            --region="${REGION}" \
            --default-service="${bs}" \
            --project="${svc}" 2>&1; then
          echo "  FAILED: URL map"
          status="failed"
        fi
      fi
    fi

    # Target HTTP proxy
    if [ "${status}" != "failed" ]; then
      if gcloud compute target-http-proxies describe "${proxy}" \
          --region="${REGION}" --project="${svc}" &>/dev/null; then
        echo "  Target HTTP proxy exists."
      else
        if ! gcloud compute target-http-proxies create "${proxy}" \
            --url-map="${urlmap}" \
            --region="${REGION}" \
            --project="${svc}" 2>&1; then
          echo "  FAILED: Target HTTP proxy"
          status="failed"
        fi
      fi
    fi

    echo "  => ${status}"
  } > "${logfile}" 2>&1

  echo "${status}" > "${RESULTS_DIR}/stack-${svc_short}-${lb_idx}.status"
}

active_pids=()
for svc in "${SVC_PROJECTS[@]}"; do
  for lb in $(seq 1 "${LB_PER_PROJECT}"); do
    create_lb_stack "${svc}" "${lb}" &
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
done
wait

# Print LB stack logs
for svc in "${SVC_PROJECTS[@]}"; do
  svc_short="${svc##*-}"
  echo ""
  echo "  LB stacks for ${svc}:"
  for lb in $(seq 1 "${LB_PER_PROJECT}"); do
    lb_idx=$(printf "%02d" "${lb}")
    logfile="${RESULTS_DIR}/stack-${svc_short}-${lb_idx}.log"
    if [ -f "${logfile}" ]; then
      cat "${logfile}"
    fi
  done
done

# ============================================================
# Step 7b: Create forwarding rules (5 per LB stack, parallel)
# ============================================================
echo ""
echo "--- Step 7b: Create ${FR_PER_LB} forwarding rules per LB (${PARALLEL} parallel) ---"

create_fr() {
  trap - EXIT
  local svc="$1"
  local lb_num="$2"
  local fr_num="$3"
  local lb_idx fr_idx
  lb_idx=$(printf "%02d" "${lb_num}")
  fr_idx=$(printf "%02d" "${fr_num}")
  local svc_short="${svc##*-}"
  local proxy="frl-px-${svc_short}-${lb_idx}"
  local fr="frl-fr-${svc_short}-${lb_idx}-${fr_idx}"
  local logfile="${RESULTS_DIR}/fr-${svc_short}-${lb_idx}-${fr_idx}.log"
  local status="created"

  {
    echo "[${svc_short} LB${lb_idx} FR${fr_idx}] Creating forwarding rule..."

    if gcloud compute forwarding-rules describe "${fr}" \
        --region="${REGION}" --project="${svc}" &>/dev/null; then
      echo "  Forwarding rule exists."
      status="skipped"
    else
      if ! gcloud compute forwarding-rules create "${fr}" \
          --region="${REGION}" \
          --load-balancing-scheme=INTERNAL_MANAGED \
          --network="projects/${HOST_PROJECT}/global/networks/${VPC_NAME}" \
          --subnet="projects/${HOST_PROJECT}/regions/${REGION}/subnetworks/${SUBNET_NAME}" \
          --target-http-proxy="${proxy}" \
          --target-http-proxy-region="${REGION}" \
          --ports=80 \
          --project="${svc}" 2>&1; then
        echo "  FAILED (may have hit limit)"
        status="failed"
      fi
    fi

    echo "  => ${status}"
  } > "${logfile}" 2>&1

  echo "${status}" > "${RESULTS_DIR}/fr-${svc_short}-${lb_idx}-${fr_idx}.status"
}

active_pids=()
for svc in "${SVC_PROJECTS[@]}"; do
  for lb in $(seq 1 "${LB_PER_PROJECT}"); do
    for fr in $(seq 1 "${FR_PER_LB}"); do
      create_fr "${svc}" "${lb}" "${fr}" &
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
  done
done
wait

# Print FR logs
for svc in "${SVC_PROJECTS[@]}"; do
  svc_short="${svc##*-}"
  echo ""
  echo "  Forwarding rules for ${svc}:"
  for lb in $(seq 1 "${LB_PER_PROJECT}"); do
    lb_idx=$(printf "%02d" "${lb}")
    for fr in $(seq 1 "${FR_PER_LB}"); do
      fr_idx=$(printf "%02d" "${fr}")
      logfile="${RESULTS_DIR}/fr-${svc_short}-${lb_idx}-${fr_idx}.log"
      if [ -f "${logfile}" ]; then
        cat "${logfile}"
      fi
    done
  done
done

# ============================================================
# Summary
# ============================================================
echo ""
echo "=========================================="
echo "  Summary"
echo "=========================================="

for svc in "${SVC_PROJECTS[@]}"; do
  svc_short="${svc##*-}"
  created=0; skipped=0; failed=0
  for lb in $(seq 1 "${LB_PER_PROJECT}"); do
    lb_idx=$(printf "%02d" "${lb}")
    for fr in $(seq 1 "${FR_PER_LB}"); do
      fr_idx=$(printf "%02d" "${fr}")
      statusfile="${RESULTS_DIR}/fr-${svc_short}-${lb_idx}-${fr_idx}.status"
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
  done
  echo "${svc}: created=${created} skipped=${skipped} failed=${failed}"
done

echo ""
echo "--- Forwarding rules on shared VPC (all projects) ---"
total=0
for svc in "${SVC_PROJECTS[@]}"; do
  count="$(gcloud compute forwarding-rules list \
    --filter="region:${REGION}" \
    --project="${svc}" \
    --format="value(name)" 2>/dev/null | wc -l | tr -d ' ')"
  echo "  ${svc}: ${count}"
  total=$((total + count))
done

host_count="$(gcloud compute forwarding-rules list \
  --filter="region:${REGION}" \
  --project="${HOST_PROJECT}" \
  --format="value(name)" 2>/dev/null | wc -l | tr -d ' ')"
echo "  ${HOST_PROJECT} (host): ${host_count}"
total=$((total + host_count))

echo ""
echo "TOTAL forwarding rules on network in ${REGION}: ${total}"
echo ""
echo "=== Next steps ==="
echo "Run ./teardown-shared-vpc.sh to clean up all resources."

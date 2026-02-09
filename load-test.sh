#!/usr/bin/env bash
#
# load-test.sh — Send requests to Cloud Run services from the compute instance
#
# This script SSHs into the compute instance via IAP and sends curl requests
# to Cloud Run services. Cross-VPC connectivity must be configured manually
# before services in other VPCs are reachable.
#
set -euo pipefail

PROJECT_ID="$(gcloud config get-value project 2>/dev/null)"
if [[ -z "$PROJECT_ID" ]]; then
  echo "ERROR: No project set. Run: gcloud config set project <PROJECT_ID>"
  exit 1
fi

REGION="europe-north2"
ZONE="${REGION}-a"
COMPUTE_INSTANCE_NAME="nat-poc-vm"

# Parse arguments
VPC_FILTER="${1:-all}"   # e.g., "5" to test only VPC 5, or "all"
CONCURRENT="${2:-5}"     # concurrent requests

NUM_VPCS=2
NUM_SUBNETS_PER_VPC=3
NUM_SERVICES_PER_SUBNET=3

echo "=== Load Test ==="
echo "Project: ${PROJECT_ID}"
echo "Target VPCs: ${VPC_FILTER}"
echo "Concurrency: ${CONCURRENT}"
echo ""

# Build list of service URLs to test
echo "Fetching Cloud Run service URLs..."
SERVICES=()

for v in $(seq 1 ${NUM_VPCS}); do
  if [[ "${VPC_FILTER}" != "all" && "${VPC_FILTER}" != "${v}" ]]; then
    continue
  fi

  for s in $(seq 1 ${NUM_SUBNETS_PER_VPC}); do
    for i in $(seq 1 ${NUM_SERVICES_PER_SUBNET}); do
      service_name="cr-v${v}-s${s}-$(printf '%02d' ${i})"
      url="$(gcloud run services describe "${service_name}" \
        --region="${REGION}" --project="${PROJECT_ID}" \
        --format='value(status.url)' 2>/dev/null || true)"
      if [[ -n "${url}" ]]; then
        SERVICES+=("${service_name}|${url}")
      fi
    done
  done
done

echo "Found ${#SERVICES[@]} services."
if [[ ${#SERVICES[@]} -eq 0 ]]; then
  echo "No services found. Deploy services first with setup-infra.sh."
  exit 1
fi

# Generate the test script to run on the compute instance
TEST_SCRIPT=$(cat <<'REMOTE_SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

CONCURRENT=__CONCURRENT__
SERVICES=(__SERVICE_LIST__)

echo "Testing ${#SERVICES[@]} services with concurrency ${CONCURRENT}..."
echo ""

running=0
success=0
fail=0

for entry in "${SERVICES[@]}"; do
  name="${entry%%|*}"
  url="${entry##*|}"

  (
    start=$(date +%s%N)
    # Get an identity token for the service
    TOKEN=$(curl -s -H "Metadata-Flavor: Google" \
      "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/identity?audience=${url}" 2>/dev/null || true)

    if [[ -n "${TOKEN}" ]]; then
      code=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer ${TOKEN}" "${url}" 2>/dev/null || echo "000")
    else
      code="no-token"
    fi

    end=$(date +%s%N)
    elapsed=$(( (end - start) / 1000000 ))
    echo "${name}: ${code} (${elapsed}ms)"
  ) &

  running=$((running + 1))
  if [[ ${running} -ge ${CONCURRENT} ]]; then
    wait -n
    running=$((running - 1))
  fi
done

wait
echo ""
echo "Load test complete."
REMOTE_SCRIPT
)

# Substitute values into the remote script
SERVICE_LIST=""
for s in "${SERVICES[@]}"; do
  SERVICE_LIST+="\"${s}\" "
done

TEST_SCRIPT="${TEST_SCRIPT/__CONCURRENT__/${CONCURRENT}}"
TEST_SCRIPT="${TEST_SCRIPT/__SERVICE_LIST__/${SERVICE_LIST}}"

# SSH into the compute instance and run the test
echo ""
echo "SSHing into ${COMPUTE_INSTANCE_NAME} and running load test..."
echo ""

gcloud compute ssh "${COMPUTE_INSTANCE_NAME}" \
  --zone="${ZONE}" \
  --tunnel-through-iap \
  --project="${PROJECT_ID}" \
  --command="${TEST_SCRIPT}"

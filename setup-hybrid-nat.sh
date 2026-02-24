#!/usr/bin/env bash
#
# setup-hybrid-nat.sh — Set up Hybrid NAT between VPC-1 and VPC-2 (idempotent)
#
# Creates HA VPN tunnels between the two VPCs, configures BGP to exchange
# only non-overlapping routes, and sets up Private NAT (Hybrid) on VPC-2
# so that Cloud Run services in VPC-2's overlapping Class E subnets can
# reach the webserver in VPC-1's compute subnet.
#
# Traffic flow: Cloud Run (VPC-2, 240.x.x.x) → Hybrid NAT → HA VPN → webserver (VPC-1, 10.2.0.x)
#
# Run this AFTER setup-infra.sh has completed.
#
set -euo pipefail

# --- Configuration ---
PROJECT_ID="${PROJECT_ID:-sb-paul-g-workshop}"

REGION="europe-north2"

# VPN
VPN_GW_1="vpn-gw-vpc1"
VPN_GW_2="vpn-gw-vpc2"
VPN_ROUTER_1="vpn-router-vpc1"
VPN_ROUTER_2="vpn-router-vpc2"
ASN_VPC1=65001
ASN_VPC2=65002

# NAT (on VPC-2 side — where Cloud Run sources traffic)
PNAT_SUBNET_NAME="pnat-subnet-vpc2"
PNAT_SUBNET_CIDR="172.16.0.0/24"
NAT_ROUTER="nat-router-vpc2"
NAT_GW="hybrid-nat-vpc2"

echo "=== Setup Hybrid NAT for project: ${PROJECT_ID} ==="
echo "Region: ${REGION}"
echo ""

# --- Helper functions ---
resource_exists() {
  "$@" &>/dev/null
  return $?
}

# --- Step 1: Create PRIVATE_NAT subnet in VPC-2 ---
echo "--- Step 1: Create PRIVATE_NAT subnet in VPC-2 ---"
if resource_exists gcloud compute networks subnets describe "${PNAT_SUBNET_NAME}" \
    --region="${REGION}" --project="${PROJECT_ID}"; then
  echo "Subnet '${PNAT_SUBNET_NAME}' already exists, skipping."
else
  gcloud compute networks subnets create "${PNAT_SUBNET_NAME}" \
    --network=vpc-2 \
    --region="${REGION}" \
    --range="${PNAT_SUBNET_CIDR}" \
    --purpose=PRIVATE_NAT \
    --project="${PROJECT_ID}"
  echo "Subnet '${PNAT_SUBNET_NAME}' (${PNAT_SUBNET_CIDR}) created in vpc-2."
fi

# --- Step 2: Create HA VPN gateways ---
echo ""
echo "--- Step 2: Create HA VPN gateways ---"
for vpc in 1 2; do
  gw_name="vpn-gw-vpc${vpc}"
  if resource_exists gcloud compute vpn-gateways describe "${gw_name}" \
      --region="${REGION}" --project="${PROJECT_ID}"; then
    echo "VPN gateway '${gw_name}' already exists, skipping."
  else
    gcloud compute vpn-gateways create "${gw_name}" \
      --network="vpc-${vpc}" \
      --region="${REGION}" \
      --project="${PROJECT_ID}"
    echo "VPN gateway '${gw_name}' created."
  fi
done

# --- Step 3: Create Cloud Routers for VPN ---
echo ""
echo "--- Step 3: Create Cloud Routers for VPN ---"
for vpc in 1 2; do
  router_name="vpn-router-vpc${vpc}"
  asn=$( [[ ${vpc} -eq 1 ]] && echo ${ASN_VPC1} || echo ${ASN_VPC2} )

  if resource_exists gcloud compute routers describe "${router_name}" \
      --region="${REGION}" --project="${PROJECT_ID}"; then
    echo "Cloud Router '${router_name}' already exists, skipping."
  else
    gcloud compute routers create "${router_name}" \
      --network="vpc-${vpc}" \
      --region="${REGION}" \
      --asn="${asn}" \
      --project="${PROJECT_ID}"
    echo "Cloud Router '${router_name}' (ASN ${asn}) created."
  fi
done

# --- Step 4: Create VPN tunnels ---
echo ""
echo "--- Step 4: Create VPN tunnels ---"

# Generate shared secret
SHARED_SECRET="$(openssl rand -base64 24)"

# Create tunnels for both interfaces (0 and 1) in both directions
for iface in 0 1; do
  # VPC-1 -> VPC-2
  tunnel_name="vpn-tunnel-vpc1-if${iface}"
  if resource_exists gcloud compute vpn-tunnels describe "${tunnel_name}" \
      --region="${REGION}" --project="${PROJECT_ID}"; then
    echo "VPN tunnel '${tunnel_name}' already exists, skipping."
  else
    gcloud compute vpn-tunnels create "${tunnel_name}" \
      --peer-gcp-gateway="${VPN_GW_2}" \
      --region="${REGION}" \
      --ike-version=2 \
      --shared-secret="${SHARED_SECRET}" \
      --router="${VPN_ROUTER_1}" \
      --vpn-gateway="${VPN_GW_1}" \
      --interface="${iface}" \
      --project="${PROJECT_ID}"
    echo "VPN tunnel '${tunnel_name}' created."
  fi

  # VPC-2 -> VPC-1
  tunnel_name="vpn-tunnel-vpc2-if${iface}"
  if resource_exists gcloud compute vpn-tunnels describe "${tunnel_name}" \
      --region="${REGION}" --project="${PROJECT_ID}"; then
    echo "VPN tunnel '${tunnel_name}' already exists, skipping."
  else
    gcloud compute vpn-tunnels create "${tunnel_name}" \
      --peer-gcp-gateway="${VPN_GW_1}" \
      --region="${REGION}" \
      --ike-version=2 \
      --shared-secret="${SHARED_SECRET}" \
      --router="${VPN_ROUTER_2}" \
      --vpn-gateway="${VPN_GW_2}" \
      --interface="${iface}" \
      --project="${PROJECT_ID}"
    echo "VPN tunnel '${tunnel_name}' created."
  fi
done

# --- Step 5: Add Cloud Router interfaces and BGP peers ---
echo ""
echo "--- Step 5: Configure BGP sessions ---"

# BGP link-local IPs:
#   Interface 0: VPC-1=169.254.0.1 <-> VPC-2=169.254.0.2
#   Interface 1: VPC-1=169.254.1.1 <-> VPC-2=169.254.1.2
for iface in 0 1; do
  vpc1_ip="169.254.${iface}.1"
  vpc2_ip="169.254.${iface}.2"

  # VPC-1 router: add interface + peer
  iface_name="vpn-if${iface}"
  peer_name="bgp-vpc2-if${iface}"

  if gcloud compute routers describe "${VPN_ROUTER_1}" \
      --region="${REGION}" --project="${PROJECT_ID}" \
      --format="value(interfaces.name)" 2>/dev/null | grep -q "${iface_name}"; then
    echo "Interface '${iface_name}' on ${VPN_ROUTER_1} already exists, skipping."
  else
    gcloud compute routers add-interface "${VPN_ROUTER_1}" \
      --interface-name="${iface_name}" \
      --ip-address="${vpc1_ip}" \
      --mask-length=30 \
      --vpn-tunnel="vpn-tunnel-vpc1-if${iface}" \
      --region="${REGION}" \
      --project="${PROJECT_ID}"
    echo "Interface '${iface_name}' added to ${VPN_ROUTER_1}."
  fi

  if gcloud compute routers describe "${VPN_ROUTER_1}" \
      --region="${REGION}" --project="${PROJECT_ID}" \
      --format="value(bgpPeers.name)" 2>/dev/null | grep -q "${peer_name}"; then
    echo "BGP peer '${peer_name}' on ${VPN_ROUTER_1} already exists, skipping."
  else
    gcloud compute routers add-bgp-peer "${VPN_ROUTER_1}" \
      --peer-name="${peer_name}" \
      --interface="${iface_name}" \
      --peer-ip-address="${vpc2_ip}" \
      --peer-asn="${ASN_VPC2}" \
      --region="${REGION}" \
      --project="${PROJECT_ID}"
    echo "BGP peer '${peer_name}' added to ${VPN_ROUTER_1}."
  fi

  # VPC-2 router: add interface + peer
  peer_name="bgp-vpc1-if${iface}"

  if gcloud compute routers describe "${VPN_ROUTER_2}" \
      --region="${REGION}" --project="${PROJECT_ID}" \
      --format="value(interfaces.name)" 2>/dev/null | grep -q "${iface_name}"; then
    echo "Interface '${iface_name}' on ${VPN_ROUTER_2} already exists, skipping."
  else
    gcloud compute routers add-interface "${VPN_ROUTER_2}" \
      --interface-name="${iface_name}" \
      --ip-address="${vpc2_ip}" \
      --mask-length=30 \
      --vpn-tunnel="vpn-tunnel-vpc2-if${iface}" \
      --region="${REGION}" \
      --project="${PROJECT_ID}"
    echo "Interface '${iface_name}' added to ${VPN_ROUTER_2}."
  fi

  if gcloud compute routers describe "${VPN_ROUTER_2}" \
      --region="${REGION}" --project="${PROJECT_ID}" \
      --format="value(bgpPeers.name)" 2>/dev/null | grep -q "${peer_name}"; then
    echo "BGP peer '${peer_name}' on ${VPN_ROUTER_2} already exists, skipping."
  else
    gcloud compute routers add-bgp-peer "${VPN_ROUTER_2}" \
      --peer-name="${peer_name}" \
      --interface="${iface_name}" \
      --peer-ip-address="${vpc1_ip}" \
      --peer-asn="${ASN_VPC1}" \
      --region="${REGION}" \
      --project="${PROJECT_ID}"
    echo "BGP peer '${peer_name}' added to ${VPN_ROUTER_2}."
  fi
done

# --- Step 6: Configure custom route advertisements ---
echo ""
echo "--- Step 6: Configure route advertisements (non-overlapping only) ---"

# VPC-1: advertise compute subnet and routable subnet
# These are the destinations Cloud Run in VPC-2 needs to reach
echo "Setting ${VPN_ROUTER_1} to advertise: 10.2.0.0/28, 10.0.0.0/28"
gcloud compute routers update "${VPN_ROUTER_1}" \
  --region="${REGION}" \
  --advertisement-mode=CUSTOM \
  --set-advertisement-ranges="10.2.0.0/28,10.0.0.0/28" \
  --project="${PROJECT_ID}" \
  --quiet
echo "${VPN_ROUTER_1} route advertisements configured."

# VPC-2: advertise routable subnet and PRIVATE_NAT subnet (for return traffic)
echo "Setting ${VPN_ROUTER_2} to advertise: 10.1.0.0/28, ${PNAT_SUBNET_CIDR}"
gcloud compute routers update "${VPN_ROUTER_2}" \
  --region="${REGION}" \
  --advertisement-mode=CUSTOM \
  --set-advertisement-ranges="10.1.0.0/28,${PNAT_SUBNET_CIDR}" \
  --project="${PROJECT_ID}" \
  --quiet
echo "${VPN_ROUTER_2} route advertisements configured."

# --- Step 7: Create dedicated Cloud Router for Hybrid NAT in VPC-2 ---
echo ""
echo "--- Step 7: Create NAT Cloud Router in VPC-2 ---"
if resource_exists gcloud compute routers describe "${NAT_ROUTER}" \
    --region="${REGION}" --project="${PROJECT_ID}"; then
  echo "Cloud Router '${NAT_ROUTER}' already exists, skipping."
else
  gcloud compute routers create "${NAT_ROUTER}" \
    --network=vpc-2 \
    --region="${REGION}" \
    --project="${PROJECT_ID}"
  echo "Cloud Router '${NAT_ROUTER}' created."
fi

# --- Step 8: Create Hybrid NAT gateway in VPC-2 ---
echo ""
echo "--- Step 8: Create Hybrid NAT gateway in VPC-2 ---"
if gcloud compute routers nats describe "${NAT_GW}" \
    --router="${NAT_ROUTER}" --region="${REGION}" --project="${PROJECT_ID}" &>/dev/null; then
  echo "NAT gateway '${NAT_GW}' already exists, skipping."
else
  # NAT traffic from all subnets in VPC-2 (Private NAT requires --nat-all-subnet-ip-ranges)
  gcloud compute routers nats create "${NAT_GW}" \
    --router="${NAT_ROUTER}" \
    --type=PRIVATE \
    --region="${REGION}" \
    --nat-all-subnet-ip-ranges \
    --endpoint-types=ENDPOINT_TYPE_VM \
    --project="${PROJECT_ID}"
  echo "NAT gateway '${NAT_GW}' created."
fi

# --- Step 9: Create NAT rule matching hybrid next hops ---
echo ""
echo "--- Step 9: Create Hybrid NAT rule ---"
if gcloud compute routers nats rules describe 100 \
    --router="${NAT_ROUTER}" --nat="${NAT_GW}" \
    --region="${REGION}" --project="${PROJECT_ID}" &>/dev/null; then
  echo "NAT rule 100 already exists, skipping."
else
  gcloud compute routers nats rules create 100 \
    --router="${NAT_ROUTER}" \
    --region="${REGION}" \
    --nat="${NAT_GW}" \
    --match='nexthop.is_hybrid' \
    --source-nat-active-ranges="${PNAT_SUBNET_NAME}" \
    --project="${PROJECT_ID}"
  echo "NAT rule 100 created (match: nexthop.is_hybrid, SNAT to ${PNAT_SUBNET_CIDR})."
fi

# --- Step 10: Firewall rule for NATted traffic into VPC-1 ---
echo ""
echo "--- Step 10: Create firewall rule for NATted traffic into VPC-1 ---"
FW_NAT="allow-hybrid-nat-ingress-vpc1"
if resource_exists gcloud compute firewall-rules describe "${FW_NAT}" --project="${PROJECT_ID}"; then
  echo "Firewall rule '${FW_NAT}' already exists, skipping."
else
  gcloud compute firewall-rules create "${FW_NAT}" \
    --network=vpc-1 \
    --allow=tcp,udp,icmp \
    --source-ranges="${PNAT_SUBNET_CIDR}" \
    --direction=INGRESS \
    --project="${PROJECT_ID}"
  echo "Firewall rule '${FW_NAT}' created."
fi

# --- Verification ---
echo ""
echo "=== Hybrid NAT setup complete ==="
echo ""
echo "Verifying..."
echo ""

echo "--- VPN tunnel status ---"
gcloud compute vpn-tunnels list \
  --filter="region:${REGION}" --project="${PROJECT_ID}" \
  --format="table(name,status,peerIp)"

echo ""
echo "--- BGP session status ---"
for vpc in 1 2; do
  router="vpn-router-vpc${vpc}"
  echo ""
  echo "${router}:"
  gcloud compute routers get-status "${router}" \
    --region="${REGION}" --project="${PROJECT_ID}" \
    --format="table(result.bgpPeerStatus[].name,result.bgpPeerStatus[].status,result.bgpPeerStatus[].numLearnedRoutes)" 2>/dev/null || echo "  (not ready yet — BGP may take a minute to converge)"
done

echo ""
echo "--- NAT gateway ---"
gcloud compute routers nats describe "${NAT_GW}" \
  --router="${NAT_ROUTER}" \
  --region="${REGION}" --project="${PROJECT_ID}" \
  --format="yaml(name,type,sourceSubnetworkIpRangesToNat,rules)" 2>/dev/null || true

echo ""
echo "=== Next steps ==="
echo ""
echo "1. Wait ~60s for BGP to converge, then verify learned routes:"
echo "   gcloud compute routers get-status ${VPN_ROUTER_2} --region=${REGION} --project=${PROJECT_ID}"
echo ""
echo "2. Test by invoking the proxy Cloud Run service (cr-proxy-v2)."
echo "   It will attempt to reach the webserver in VPC-1 via the VPN,"
echo "   with its source IP NATted from 240.x.x.x to ${PNAT_SUBNET_CIDR}."

#!/usr/bin/env bash
#
# vpc-connector/setup-connectivity.sh — Set up HA VPN, BGP, Public NAT, and ILB (idempotent)
#
# Creates cross-VPC connectivity between hub and both connector spokes:
#   - HA VPN tunnels with BGP (hub ↔ spoke-c1, hub ↔ spoke-c2)
#   - Public NAT on hub (internet access for VM)
#   - ILB with serverless NEG on each spoke (hub→spoke traffic)
#
# Key difference from Direct VPC Egress: NO Hybrid NAT needed.
# Connector VM IPs are already unique and routable.
#
# Run this AFTER setup-infra.sh has completed.
# Wait ~60s after completion for BGP to converge before testing.
#
set -euo pipefail

# --- Configuration ---
PROJECT_ID="${PROJECT_ID:-sb-paul-g-vpcsac}"

REGION="europe-north2"
HUB_ASN=65000

echo "=== Setup Connectivity (VPC Connector) for project: ${PROJECT_ID} ==="
echo "Region: ${REGION}"
echo ""

# --- Helper ---
resource_exists() {
  "$@" &>/dev/null
  return $?
}

# ============================================================
# Step 1: Hub VPN Cloud Router (shared, idempotent)
# ============================================================
echo "--- Step 1: Hub VPN Cloud Router ---"
if resource_exists gcloud compute routers describe "vpn-router-hub" \
    --region="${REGION}" --project="${PROJECT_ID}"; then
  echo "Cloud Router 'vpn-router-hub' already exists, skipping."
else
  gcloud compute routers create "vpn-router-hub" \
    --network=hub \
    --region="${REGION}" \
    --asn="${HUB_ASN}" \
    --project="${PROJECT_ID}"
  echo "Cloud Router 'vpn-router-hub' (ASN ${HUB_ASN}) created."
fi

# ============================================================
# Step 2: Per-spoke VPN setup
# ============================================================
for spoke_num in 1 2; do
  spoke="spoke-c${spoke_num}"
  spoke_asn=$((65002 + spoke_num))  # 65003, 65004

  echo ""
  echo "=========================================="
  echo "  Setting up VPN: hub ↔ ${spoke}"
  echo "=========================================="

  # --- Spoke VPN Cloud Router ---
  spoke_router="vpn-router-${spoke}"
  if resource_exists gcloud compute routers describe "${spoke_router}" \
      --region="${REGION}" --project="${PROJECT_ID}"; then
    echo "Cloud Router '${spoke_router}' already exists, skipping."
  else
    gcloud compute routers create "${spoke_router}" \
      --network="${spoke}" \
      --region="${REGION}" \
      --asn="${spoke_asn}" \
      --project="${PROJECT_ID}"
    echo "Cloud Router '${spoke_router}' (ASN ${spoke_asn}) created."
  fi

  # --- HA VPN gateways ---
  hub_gw="vpn-gw-hub-to-${spoke}"
  spoke_gw="vpn-gw-${spoke}"

  if resource_exists gcloud compute vpn-gateways describe "${hub_gw}" \
      --region="${REGION}" --project="${PROJECT_ID}"; then
    echo "VPN gateway '${hub_gw}' already exists, skipping."
  else
    gcloud compute vpn-gateways create "${hub_gw}" \
      --network=hub \
      --region="${REGION}" \
      --project="${PROJECT_ID}"
    echo "VPN gateway '${hub_gw}' created."
  fi

  if resource_exists gcloud compute vpn-gateways describe "${spoke_gw}" \
      --region="${REGION}" --project="${PROJECT_ID}"; then
    echo "VPN gateway '${spoke_gw}' already exists, skipping."
  else
    gcloud compute vpn-gateways create "${spoke_gw}" \
      --network="${spoke}" \
      --region="${REGION}" \
      --project="${PROJECT_ID}"
    echo "VPN gateway '${spoke_gw}' created."
  fi

  # --- VPN tunnels (2 per direction = 4 per spoke) ---
  SHARED_SECRET="$(openssl rand -base64 24)"

  for iface in 0 1; do
    # Hub → Spoke
    tunnel="vpn-tunnel-hub-to-${spoke}-if${iface}"
    if resource_exists gcloud compute vpn-tunnels describe "${tunnel}" \
        --region="${REGION}" --project="${PROJECT_ID}"; then
      echo "VPN tunnel '${tunnel}' already exists, skipping."
    else
      gcloud compute vpn-tunnels create "${tunnel}" \
        --peer-gcp-gateway="${spoke_gw}" \
        --region="${REGION}" \
        --ike-version=2 \
        --shared-secret="${SHARED_SECRET}" \
        --router="vpn-router-hub" \
        --vpn-gateway="${hub_gw}" \
        --interface="${iface}" \
        --project="${PROJECT_ID}"
      echo "VPN tunnel '${tunnel}' created."
    fi

    # Spoke → Hub
    tunnel="vpn-tunnel-${spoke}-to-hub-if${iface}"
    if resource_exists gcloud compute vpn-tunnels describe "${tunnel}" \
        --region="${REGION}" --project="${PROJECT_ID}"; then
      echo "VPN tunnel '${tunnel}' already exists, skipping."
    else
      gcloud compute vpn-tunnels create "${tunnel}" \
        --peer-gcp-gateway="${hub_gw}" \
        --region="${REGION}" \
        --ike-version=2 \
        --shared-secret="${SHARED_SECRET}" \
        --router="${spoke_router}" \
        --vpn-gateway="${spoke_gw}" \
        --interface="${iface}" \
        --project="${PROJECT_ID}"
      echo "VPN tunnel '${tunnel}' created."
    fi
  done

  # --- BGP sessions ---
  echo ""
  echo "  Configuring BGP sessions for hub ↔ ${spoke}..."

  # BGP link-local IPs — offset by 2 from direct-vpc-egress spokes to avoid conflicts
  #   spoke-c1 iface 0: hub=169.254.3.1 ↔ spoke=169.254.3.2
  #   spoke-c1 iface 1: hub=169.254.3.5 ↔ spoke=169.254.3.6
  #   spoke-c2 iface 0: hub=169.254.4.1 ↔ spoke=169.254.4.2
  #   spoke-c2 iface 1: hub=169.254.4.5 ↔ spoke=169.254.4.6
  bgp_octet=$((spoke_num + 2))  # 3, 4
  for iface in 0 1; do
    hub_ip="169.254.${bgp_octet}.$((iface * 4 + 1))"
    spoke_ip="169.254.${bgp_octet}.$((iface * 4 + 2))"

    # Hub side
    hub_iface_name="vpn-${spoke}-if${iface}"
    hub_peer_name="bgp-${spoke}-if${iface}"

    if gcloud compute routers describe "vpn-router-hub" \
        --region="${REGION}" --project="${PROJECT_ID}" \
        --format="value(interfaces.name)" 2>/dev/null | tr ';' '\n' | grep -qx "${hub_iface_name}"; then
      echo "  Interface '${hub_iface_name}' on vpn-router-hub already exists, skipping."
    else
      gcloud compute routers add-interface "vpn-router-hub" \
        --interface-name="${hub_iface_name}" \
        --ip-address="${hub_ip}" \
        --mask-length=30 \
        --vpn-tunnel="vpn-tunnel-hub-to-${spoke}-if${iface}" \
        --region="${REGION}" \
        --project="${PROJECT_ID}"
      echo "  Interface '${hub_iface_name}' added to vpn-router-hub."
    fi

    if gcloud compute routers describe "vpn-router-hub" \
        --region="${REGION}" --project="${PROJECT_ID}" \
        --format="value(bgpPeers.name)" 2>/dev/null | tr ';' '\n' | grep -qx "${hub_peer_name}"; then
      echo "  BGP peer '${hub_peer_name}' on vpn-router-hub already exists, skipping."
    else
      gcloud compute routers add-bgp-peer "vpn-router-hub" \
        --peer-name="${hub_peer_name}" \
        --interface="${hub_iface_name}" \
        --peer-ip-address="${spoke_ip}" \
        --peer-asn="${spoke_asn}" \
        --region="${REGION}" \
        --project="${PROJECT_ID}"
      echo "  BGP peer '${hub_peer_name}' added to vpn-router-hub."
    fi

    # Spoke side
    spoke_iface_name="vpn-hub-if${iface}"
    spoke_peer_name="bgp-hub-if${iface}"

    if gcloud compute routers describe "${spoke_router}" \
        --region="${REGION}" --project="${PROJECT_ID}" \
        --format="value(interfaces.name)" 2>/dev/null | tr ';' '\n' | grep -qx "${spoke_iface_name}"; then
      echo "  Interface '${spoke_iface_name}' on ${spoke_router} already exists, skipping."
    else
      gcloud compute routers add-interface "${spoke_router}" \
        --interface-name="${spoke_iface_name}" \
        --ip-address="${spoke_ip}" \
        --mask-length=30 \
        --vpn-tunnel="vpn-tunnel-${spoke}-to-hub-if${iface}" \
        --region="${REGION}" \
        --project="${PROJECT_ID}"
      echo "  Interface '${spoke_iface_name}' added to ${spoke_router}."
    fi

    if gcloud compute routers describe "${spoke_router}" \
        --region="${REGION}" --project="${PROJECT_ID}" \
        --format="value(bgpPeers.name)" 2>/dev/null | tr ';' '\n' | grep -qx "${spoke_peer_name}"; then
      echo "  BGP peer '${spoke_peer_name}' on ${spoke_router} already exists, skipping."
    else
      gcloud compute routers add-bgp-peer "${spoke_router}" \
        --peer-name="${spoke_peer_name}" \
        --interface="${spoke_iface_name}" \
        --peer-ip-address="${hub_ip}" \
        --peer-asn="${HUB_ASN}" \
        --region="${REGION}" \
        --project="${PROJECT_ID}"
      echo "  BGP peer '${spoke_peer_name}' added to ${spoke_router}."
    fi
  done
done

# ============================================================
# Step 3: Route advertisements
# ============================================================
echo ""
echo "--- Step 3: Configure route advertisements ---"

# Hub: advertise compute subnet
# NOTE: If both approaches coexist, the hub router may already have advertisements
# from the Direct VPC Egress approach. This update is additive.
echo "Setting vpn-router-hub to advertise: 10.0.0.0/28"
gcloud compute routers update "vpn-router-hub" \
  --region="${REGION}" \
  --advertisement-mode=CUSTOM \
  --set-advertisement-ranges="10.0.0.0/28" \
  --project="${PROJECT_ID}" \
  --quiet
echo "vpn-router-hub route advertisements configured."

# Each spoke: advertise connector + routable subnets (no PNAT — not needed!)
for spoke_num in 1 2; do
  spoke="spoke-c${spoke_num}"
  router="vpn-router-${spoke}"
  ranges="10.10.${spoke_num}.0/28,10.1${spoke_num}.0.0/22"
  echo "Setting ${router} to advertise: ${ranges}"
  gcloud compute routers update "${router}" \
    --region="${REGION}" \
    --advertisement-mode=CUSTOM \
    --set-advertisement-ranges="${ranges}" \
    --project="${PROJECT_ID}" \
    --quiet
  echo "${router} route advertisements configured."
done

# ============================================================
# Step 4: Public NAT on hub (internet access for VM) — NO Hybrid NAT needed!
# ============================================================
echo ""
echo "--- Step 4: Configure Public NAT on hub (NO Hybrid NAT needed) ---"

if resource_exists gcloud compute routers describe "nat-router-hub" \
    --region="${REGION}" --project="${PROJECT_ID}"; then
  echo "Cloud Router 'nat-router-hub' already exists, skipping."
else
  gcloud compute routers create "nat-router-hub" \
    --network=hub \
    --region="${REGION}" \
    --project="${PROJECT_ID}"
  echo "Cloud Router 'nat-router-hub' created."
fi

if gcloud compute routers nats describe "public-nat-hub" \
    --router="nat-router-hub" --region="${REGION}" --project="${PROJECT_ID}" &>/dev/null; then
  echo "NAT gateway 'public-nat-hub' already exists, skipping."
else
  gcloud compute routers nats create "public-nat-hub" \
    --router="nat-router-hub" \
    --region="${REGION}" \
    --auto-allocate-nat-external-ips \
    --nat-all-subnet-ip-ranges \
    --project="${PROJECT_ID}"
  echo "NAT gateway 'public-nat-hub' created."
fi

# ============================================================
# Step 5: ILB with serverless NEG on each spoke (hub→spoke)
# ============================================================
echo ""
echo "--- Step 5: Configure ILB on spokes ---"

# Generate and upload self-signed TLS certificates (one per spoke)
for spoke_num in 1 2; do
  cert_name="ssl-spoke-c${spoke_num}"
  if resource_exists gcloud compute ssl-certificates describe "${cert_name}" \
      --region="${REGION}" --project="${PROJECT_ID}"; then
    echo "  SSL certificate '${cert_name}' already exists, skipping."
  else
    openssl req -x509 -newkey rsa:2048 -nodes \
      -keyout "/tmp/key-spoke-c${spoke_num}.pem" \
      -out "/tmp/cert-spoke-c${spoke_num}.pem" \
      -days 365 \
      -subj "/CN=ilb-spoke-c${spoke_num}.internal" 2>/dev/null
    gcloud compute ssl-certificates create "${cert_name}" \
      --certificate="/tmp/cert-spoke-c${spoke_num}.pem" \
      --private-key="/tmp/key-spoke-c${spoke_num}.pem" \
      --region="${REGION}" \
      --project="${PROJECT_ID}"
    rm -f "/tmp/key-spoke-c${spoke_num}.pem" "/tmp/cert-spoke-c${spoke_num}.pem"
    echo "  SSL certificate '${cert_name}' created."
  fi
done

for spoke_num in 1 2; do
  spoke="spoke-c${spoke_num}"
  service="cr-${spoke}"

  echo ""
  echo "  Setting up ILB for ${spoke}..."

  # Serverless NEG
  neg="neg-${spoke}"
  if resource_exists gcloud compute network-endpoint-groups describe "${neg}" \
      --region="${REGION}" --project="${PROJECT_ID}"; then
    echo "  NEG '${neg}' already exists, skipping."
  else
    gcloud compute network-endpoint-groups create "${neg}" \
      --region="${REGION}" \
      --network-endpoint-type=serverless \
      --cloud-run-service="${service}" \
      --project="${PROJECT_ID}"
    echo "  NEG '${neg}' created."
  fi

  # Backend service
  bs="bs-${spoke}"
  if resource_exists gcloud compute backend-services describe "${bs}" \
      --region="${REGION}" --project="${PROJECT_ID}"; then
    echo "  Backend service '${bs}' already exists, skipping."
  else
    gcloud compute backend-services create "${bs}" \
      --region="${REGION}" \
      --load-balancing-scheme=INTERNAL_MANAGED \
      --protocol=HTTP \
      --project="${PROJECT_ID}"
    echo "  Backend service '${bs}' created."

    gcloud compute backend-services add-backend "${bs}" \
      --region="${REGION}" \
      --network-endpoint-group="${neg}" \
      --network-endpoint-group-region="${REGION}" \
      --project="${PROJECT_ID}"
    echo "  NEG '${neg}' added to backend service '${bs}'."
  fi

  # URL map
  urlmap="urlmap-${spoke}"
  if resource_exists gcloud compute url-maps describe "${urlmap}" \
      --region="${REGION}" --project="${PROJECT_ID}"; then
    echo "  URL map '${urlmap}' already exists, skipping."
  else
    gcloud compute url-maps create "${urlmap}" \
      --region="${REGION}" \
      --default-service="${bs}" \
      --project="${PROJECT_ID}"
    echo "  URL map '${urlmap}' created."
  fi

  # Target HTTPS proxy
  proxy="proxy-${spoke}"
  if resource_exists gcloud compute target-https-proxies describe "${proxy}" \
      --region="${REGION}" --project="${PROJECT_ID}"; then
    echo "  Target HTTPS proxy '${proxy}' already exists, skipping."
  else
    gcloud compute target-https-proxies create "${proxy}" \
      --ssl-certificates="ssl-${spoke}" \
      --url-map="${urlmap}" \
      --region="${REGION}" \
      --project="${PROJECT_ID}"
    echo "  Target HTTPS proxy '${proxy}' created."
  fi

  # Forwarding rule
  fr="ilb-${spoke}"
  if resource_exists gcloud compute forwarding-rules describe "${fr}" \
      --region="${REGION}" --project="${PROJECT_ID}"; then
    echo "  Forwarding rule '${fr}' already exists, skipping."
  else
    gcloud compute forwarding-rules create "${fr}" \
      --region="${REGION}" \
      --load-balancing-scheme=INTERNAL_MANAGED \
      --network="${spoke}" \
      --subnet="routable-${spoke}" \
      --target-https-proxy="${proxy}" \
      --target-https-proxy-region="${REGION}" \
      --ports=443 \
      --project="${PROJECT_ID}"
    echo "  Forwarding rule '${fr}' created."
  fi
done

# ============================================================
# Verification
# ============================================================
echo ""
echo "=== Connectivity setup complete (VPC Connector) ==="
echo ""
echo "--- VPN tunnel status ---"
gcloud compute vpn-tunnels list \
  --filter="region:${REGION} AND name~spoke-c" --project="${PROJECT_ID}" \
  --format="table(name,status,peerIp)"

echo ""
echo "--- BGP session status ---"
for router in vpn-router-hub vpn-router-spoke-c1 vpn-router-spoke-c2; do
  if resource_exists gcloud compute routers describe "${router}" \
      --region="${REGION}" --project="${PROJECT_ID}"; then
    echo ""
    echo "${router}:"
    gcloud compute routers get-status "${router}" \
      --region="${REGION}" --project="${PROJECT_ID}" \
      --format="table(result.bgpPeerStatus[].name,result.bgpPeerStatus[].status,result.bgpPeerStatus[].numLearnedRoutes)" 2>/dev/null \
      || echo "  (not ready yet — BGP may take a minute to converge)"
  fi
done

echo ""
echo "--- ILB forwarding rules ---"
for spoke_num in 1 2; do
  fr="ilb-spoke-c${spoke_num}"
  ip="$(gcloud compute forwarding-rules describe "${fr}" \
    --region="${REGION}" --project="${PROJECT_ID}" \
    --format='get(IPAddress)' 2>/dev/null || echo 'unknown')"
  echo "  ${fr}: ${ip}"
done

echo ""
echo "=== Next steps ==="
echo ""
echo "1. Wait ~60s for BGP to converge"
echo "2. Run ./test.sh to verify both traffic flows"
echo "3. Run ./teardown.sh when done to avoid ongoing VPN costs (~\$0.60/hr)"

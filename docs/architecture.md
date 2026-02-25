# Hub-Spoke Architecture

## Overview

This PoC demonstrates how Cloud Run services deployed on **overlapping IP ranges** (Class E `240.0.0.0/8`) across separate VPCs can communicate with a central hub VM — and vice versa — using HA VPN, Hybrid NAT, and Internal Load Balancers.

## Key Findings

**Can we use overlapping non-routable IP addresses in a Google Cloud network?**

Yes. GCP allows Class E addresses (`240.0.0.0/4`) as VPC subnet ranges. Multiple VPCs can use the same Class E CIDR (e.g. `240.0.0.0/8`) without conflict, since each VPC is an isolated network. Cloud Run services deployed with Direct VPC egress into these subnets function normally. Cross-VPC communication is possible via Hybrid NAT (which translates the overlapping source IPs to unique routable IPs) combined with HA VPN tunnels.

**Can we use non-routable IP addresses for the proxy-only subnet?**

Yes. GCP accepts Class E ranges for `REGIONAL_MANAGED_PROXY` purpose subnets (e.g. `241.0.0.0/26`). The Envoy proxies provisioned by the Internal Load Balancer operate entirely within the VPC — their IPs never appear in cross-VPC traffic. This means the proxy-only subnet can use the same overlapping range in every spoke, doesn't need to be advertised via BGP, and consumes zero routable address space.

## Topology

![Hub-Spoke Architecture](diagrams/architecture.svg)

## Traffic Flows

![Traffic Flows](diagrams/traffic-flows.svg)

### Flow A — Spoke → Hub (Hybrid NAT)

Cloud Run Job (240.x.x.x) → **Hybrid NAT** (SNATs to 172.16.x.x) → HA VPN → VM (10.0.0.x)

The overlapping Class E source IPs are translated to unique routable IPs in the `172.16.x.0/24` PRIVATE_NAT subnet before crossing the VPN tunnel. The hub VM sees the NATted IP as the source.

### Flow B — Hub → Spoke (ILB)

VM (10.0.0.x) → HA VPN → **ILB** (10.x.0.x) → serverless NEG → Cloud Run service

The hub VM sends traffic to the spoke's Internal Load Balancer (on a routable /28 subnet advertised via BGP). The ILB routes to a serverless NEG pointing at the Cloud Run service. No NAT is needed in this direction since the ILB uses a routable IP.

## Subnets

| Subnet | VPC | CIDR | Purpose |
|---|---|---|---|
| `compute-hub` | `hub` | `10.0.0.0/28` | VM (Private Google Access enabled) |
| `overlap-spoke1` | `spoke-1` | `240.0.0.0/8` | Cloud Run egress (overlapping) |
| `overlap-spoke2` | `spoke-2` | `240.0.0.0/8` | Cloud Run egress (overlapping) |
| `routable-spoke1` | `spoke-1` | `10.1.0.0/28` | ILB forwarding rule |
| `routable-spoke2` | `spoke-2` | `10.2.0.0/28` | ILB forwarding rule |
| `proxy-spoke1` | `spoke-1` | `241.0.0.0/26` | ILB proxy-only (REGIONAL_MANAGED_PROXY, overlapping) |
| `proxy-spoke2` | `spoke-2` | `241.0.0.0/26` | ILB proxy-only (REGIONAL_MANAGED_PROXY, overlapping) |
| `pnat-spoke1` | `spoke-1` | `172.16.1.0/24` | Hybrid NAT source IPs (PRIVATE_NAT) |
| `pnat-spoke2` | `spoke-2` | `172.16.2.0/24` | Hybrid NAT source IPs (PRIVATE_NAT) |

## VPN & BGP

- **Hub router** (`vpn-router-hub`, ASN 65000): shared across both spoke connections
- **2 hub VPN gateways** (`vpn-gw-hub-to-spoke1`, `vpn-gw-hub-to-spoke2`): one per spoke
- **2 spoke routers/gateways**: ASN 65001 (spoke-1), ASN 65002 (spoke-2)
- **8 VPN tunnels** total (2 HA interfaces × 2 directions × 2 spokes)

### Route Advertisements

| Router | Advertises |
|---|---|
| Hub | `10.0.0.0/28` (compute subnet) |
| Spoke-1 | `10.1.0.0/28`, `172.16.1.0/24` |
| Spoke-2 | `10.2.0.0/28`, `172.16.2.0/24` |

Only non-overlapping routes are exchanged. The overlapping `240.0.0.0/8` and `241.0.0.0/26` subnets are **never advertised** — they exist only within each spoke for Cloud Run egress and ILB proxy capacity respectively.

## NAT Configuration

### Hybrid NAT (per spoke)

Each spoke has a dedicated Cloud Router (`nat-router-spoke-{n}`) with a Private NAT gateway (`hybrid-nat-spoke-{n}`). A NAT rule matches `nexthop.is_hybrid` (traffic destined for routes learned via VPN) and SNATs to the spoke's `pnat-spoke-{n}` subnet (`172.16.{n}.0/24`).

This translates the overlapping `240.x.x.x` source IPs into unique routable IPs before the traffic crosses the VPN tunnel.

### Public NAT (hub)

The hub has a Public NAT gateway (`public-nat-hub`) on a dedicated Cloud Router (`nat-router-hub`) giving the VM internet access despite having no external IP.

## ILB Configuration (per spoke)

Each spoke exposes its Cloud Run service via an Internal Load Balancer:

1. **Serverless NEG** (`neg-spoke-{n}`) → points at `cr-spoke-{n}`
2. **Backend service** (`bs-spoke-{n}`) → regional, INTERNAL_MANAGED, HTTP
3. **URL map** (`urlmap-spoke-{n}`) → default backend
4. **Target HTTP proxy** (`proxy-spoke-{n}`)
5. **Forwarding rule** (`ilb-spoke-{n}`) → on `routable-spoke-{n}` subnet, port 80

The ILB's IP is on the routable `/28` subnet, which is advertised via BGP to the hub. The proxy-only subnet provides Envoy proxy capacity.

## Compute & Cloud Run

| Resource | VPC / Subnet | Purpose |
|---|---|---|
| `vm-hub` (e2-micro) | hub / compute-hub | Webserver (python3 http.server on port 80) + test client |
| `cr-spoke-1` | spoke-1 / overlap-spoke-1 | Cloud Run service (Go HTTP server, private ingress) |
| `cr-spoke-2` | spoke-2 / overlap-spoke-2 | Cloud Run service (Go HTTP server, private ingress) |
| `job-spoke-1` | spoke-1 / overlap-spoke-1 | Cloud Run Job — test client, calls VM via NAT |
| `job-spoke-2` | spoke-2 / overlap-spoke-2 | Cloud Run Job — test client, calls VM via NAT |

## Firewall Rules

| Rule | VPC | Source | Allow |
|---|---|---|---|
| `allow-iap-ssh-hub` | hub | `35.235.240.0/20` | tcp:22 |
| `allow-nat-ingress-hub` | hub | `172.16.0.0/16` | tcp,udp,icmp |
| `allow-internal-hub` | hub | `10.0.0.0/8` | tcp,udp,icmp |
| `allow-internal-spoke-1` | spoke-1 | `10.0.0.0/8,172.16.0.0/16` | tcp,udp,icmp |
| `allow-internal-spoke-2` | spoke-2 | `10.0.0.0/8,172.16.0.0/16` | tcp,udp,icmp |

## Cost Estimate

| Resource | Qty | Monthly Cost |
|---|---|---|
| HA VPN tunnels | 8 | ~$438 |
| ILB proxy instances | 2 | ~$36 |
| Public Cloud NAT | 1 | ~$32 |
| Compute VM (e2-micro) | 1 | ~$6 |
| Cloud Run (idle) | 2 svc + 2 jobs | $0 |
| Cloud Routers | 6 | Free |
| **Total (always-on)** | | **~$512/month** |

**VPN is the dominant cost.** For a PoC that runs a few hours at a time: 8 tunnels × $0.075/hr × 4 hours = **~$2.40 per session**. Tear down after each test session.

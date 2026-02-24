# Hub-Spoke Architecture

## Overview

This PoC demonstrates how Cloud Run services deployed on **overlapping IP ranges** (Class E `240.0.0.0/8`) across separate VPCs can communicate with a central hub VM — and vice versa — using HA VPN, Hybrid NAT, and Internal Load Balancers.

## Topology

```
                     HA VPN (4 tunnels)              HA VPN (4 tunnels)
  +-----------+  <========================>  +-----+  <========================>  +-----------+
  |  spoke-1  |                              | hub |                              |  spoke-2  |
  +-----------+                              +-----+                              +-----------+
  CR service          Hybrid NAT             VM (webserver                        CR service
  CR job (test)       (spoke→hub)            + test client)     Hybrid NAT        CR job (test)
  240.0.0.0/8                                10.0.0.0/28       (spoke→hub)        240.0.0.0/8
  ILB on 10.1.0.0/28                         Public NAT                           ILB on 10.2.0.0/28
                                             (internet access)
```

## Traffic Flows

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
| `proxy-spoke1` | `spoke-1` | `10.1.1.0/26` | ILB proxy-only (REGIONAL_MANAGED_PROXY) |
| `proxy-spoke2` | `spoke-2` | `10.2.1.0/26` | ILB proxy-only (REGIONAL_MANAGED_PROXY) |
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
| Spoke-1 | `10.1.0.0/28`, `10.1.1.0/26`, `172.16.1.0/24` |
| Spoke-2 | `10.2.0.0/28`, `10.2.1.0/26`, `172.16.2.0/24` |

Only non-overlapping routes are exchanged. The overlapping `240.0.0.0/8` subnets are **never advertised** — they exist only within each spoke for Cloud Run egress.

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

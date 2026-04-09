# VPC Connector Approach — Architecture

![Hub-Spoke Architecture](diagrams/architecture.svg)

![Traffic Flows](diagrams/traffic-flows.svg)

## Overview

This approach uses **VPC Serverless Access Connectors** to connect Cloud Run services to spoke VPCs, instead of Direct VPC Egress. The connector acts as a NAT boundary — Cloud Run traffic exits with the connector VM's IP (from a unique `/28` subnet), eliminating the need for overlapping IP subnets and Hybrid NAT.

## Key Architectural Differences from Direct VPC Egress

| Aspect | Direct VPC Egress | VPC Connector |
|---|---|---|
| Cloud Run networking | `--network`/`--subnet` (deploys into VPC) | `--vpc-connector` (connects through VMs) |
| Overlapping subnet | Required (`240.0.0.0/20`) | Not needed |
| Hybrid NAT | Required (SNAT overlapping → unique) | Not needed |
| PNAT subnet | Required (`172.16.x.0/24`) | Not needed |
| Subnets per spoke | 4 (overlap, routable, proxy, pnat) | 3 (connector, routable, proxy) |
| NAT boundary | Hybrid NAT gateway | Connector VM itself |

## Topology

```
                    ┌──────────────────────────────────────┐
                    │          Hub VPC                      │
                    │  ┌──────────────────────────────────┐ │
                    │  │ compute-hub (10.0.0.0/28)        │ │
                    │  │   vm-hub (e2-micro, HTTP :80)    │ │
                    │  └──────────────────────────────────┘ │
                    │                                      │
                    │  vpn-router-hub (ASN 65000)          │
                    │  public-nat-hub                      │
                    └───────────┬──────────┬───────────────┘
                                │          │
                         HA VPN │          │ HA VPN
                      4 tunnels │          │ 4 tunnels
                                │          │
        ┌───────────────────────┴──┐  ┌────┴──────────────────────┐
        │     Spoke-C1 VPC         │  │     Spoke-C2 VPC          │
        │                          │  │                           │
        │  connector-spoke-c1      │  │  connector-spoke-c2       │
        │  (10.10.1.0/28)          │  │  (10.10.2.0/28)           │
        │    VPC Connector VMs     │  │    VPC Connector VMs      │
        │                          │  │                           │
        │  routable-spoke-c1       │  │  routable-spoke-c2        │
        │  (10.11.0.0/22)          │  │  (10.12.0.0/22)           │
        │    ILB (HTTPS :443)      │  │    ILB (HTTPS :443)       │
        │                          │  │                           │
        │  proxy-spoke-c1          │  │  proxy-spoke-c2           │
        │  (241.0.0.0/18)          │  │  (241.0.0.0/18)           │
        │                          │  │                           │
        │  cr-spoke-c1 (service)   │  │  cr-spoke-c2 (service)    │
        │  job-spoke-c1 (job)      │  │  job-spoke-c2 (job)       │
        │                          │  │                           │
        │  vpn-router-spoke-c1     │  │  vpn-router-spoke-c2      │
        │  (ASN 65003)             │  │  (ASN 65004)              │
        └──────────────────────────┘  └───────────────────────────┘
```

## Traffic Flows

### Flow A: Spoke → Hub (simpler than Direct VPC Egress)

```
Cloud Run Job
    │
    ▼
VPC Connector VM (10.10.x.x)    ← connector subnet IP, already unique
    │
    ▼
HA VPN Tunnel                    ← no SNAT needed, IP is routable
    │
    ▼
Hub VM (10.0.0.x:80)
```

No Hybrid NAT step. The connector VM IP is already unique and routable across the hub-spoke topology.

### Flow B: Hub → Spoke (same as Direct VPC Egress)

```
Hub VM (10.0.0.x)
    │
    ▼
HA VPN Tunnel
    │
    ▼
ILB Forwarding Rule (10.1x.0.x:443)
    │
    ▼
Envoy Proxy (241.0.0.x)          ← proxy-only subnet, internal
    │
    ▼
Serverless NEG → Cloud Run Service
```

## Subnets

| Subnet | VPC | CIDR | Purpose |
|---|---|---|---|
| `compute-hub` | `hub` | `10.0.0.0/28` | VM |
| `connector-spoke-c1` | `spoke-c1` | `10.10.1.0/28` | VPC Connector (unique, routable) |
| `connector-spoke-c2` | `spoke-c2` | `10.10.2.0/28` | VPC Connector (unique, routable) |
| `routable-spoke-c1` | `spoke-c1` | `10.11.0.0/22` | ILB forwarding rule |
| `routable-spoke-c2` | `spoke-c2` | `10.12.0.0/22` | ILB forwarding rule |
| `proxy-spoke-c1` | `spoke-c1` | `241.0.0.0/18` | ILB proxy-only (overlapping OK) |
| `proxy-spoke-c2` | `spoke-c2` | `241.0.0.0/18` | ILB proxy-only (overlapping OK) |

7 subnets total vs 10 for Direct VPC Egress (no overlap or pnat subnets).

## VPN & BGP

| Router | VPC | ASN | Advertises |
|---|---|---|---|
| `vpn-router-hub` | `hub` | 65000 | `10.0.0.0/28` |
| `vpn-router-spoke-c1` | `spoke-c1` | 65003 | `10.10.1.0/28`, `10.11.0.0/22` |
| `vpn-router-spoke-c2` | `spoke-c2` | 65004 | `10.10.2.0/28`, `10.12.0.0/22` |

- 2 BGP routes per spoke (vs 2 for Direct VPC Egress — same density)
- 4 tunnels per spoke (2 interfaces × 2 directions), 8 total
- ASNs 65003/65004 avoid conflict with Direct VPC Egress ASNs (65001/65002)
- BGP link-local IPs use 169.254.3.x and 169.254.4.x (avoiding 169.254.1.x and 169.254.2.x used by Direct VPC Egress)

## VPC Access Connectors

| Connector | VPC | Subnet | Machine Type | Instances |
|---|---|---|---|---|
| `connector-spoke-c1` | `spoke-c1` | `connector-spoke-c1` | e2-micro | 2-3 |
| `connector-spoke-c2` | `spoke-c2` | `connector-spoke-c2` | e2-micro | 2-3 |

- Each connector uses 2-3 e2-micro VMs
- Max throughput: ~200 Mbps per e2-micro
- Connector IPs come from the `/28` subnet (unique per spoke)

## ILB Configuration

Same architecture as Direct VPC Egress:
- Self-signed TLS certificate per spoke
- Serverless NEG pointing to Cloud Run service
- Backend service with INTERNAL_MANAGED scheme
- URL map → target HTTPS proxy → forwarding rule on port 443

> **Scaling note**: GCP enforces a hard system limit of **75 regional internal managed forwarding rules per region per VPC network** (not adjustable). The PoC uses 2 forwarding rules (1 per spoke), but at production scale URL-map routing (1 FR per spoke with host/path rules) is required. See [scaling-analysis.md](../direct-vpc-egress/docs/scaling-analysis.md) §2.2.

## Firewall Rules

| Rule | VPC | Allows | Source Ranges |
|---|---|---|---|
| `allow-iap-ssh-hub` | `hub` | TCP:22 | `35.235.240.0/20` (IAP) |
| `allow-nat-ingress-hub` | `hub` | TCP, UDP, ICMP | `172.16.0.0/16` |
| `allow-internal-hub` | `hub` | TCP, UDP, ICMP | `10.0.0.0/8` |
| `allow-internal-spoke-c1` | `spoke-c1` | TCP, UDP, ICMP | `10.0.0.0/8` |
| `allow-internal-spoke-c2` | `spoke-c2` | TCP, UDP, ICMP | `10.0.0.0/8` |

Spoke firewall rules only need `10.0.0.0/8` (no `172.16.0.0/16` needed since there's no Hybrid NAT).

## Compute & Cloud Run Resources

| Resource | Type | VPC | Notes |
|---|---|---|---|
| `vm-hub` | Compute VM | `hub` | e2-micro, python3 HTTP server |
| `cr-spoke-c1` | Cloud Run service | `spoke-c1` | Via VPC Connector |
| `cr-spoke-c2` | Cloud Run service | `spoke-c2` | Via VPC Connector |
| `job-spoke-c1` | Cloud Run job | `spoke-c1` | Test client, via VPC Connector |
| `job-spoke-c2` | Cloud Run job | `spoke-c2` | Test client, via VPC Connector |

## Cost Estimate

| Resource | Monthly Cost |
|---|---|
| HA VPN tunnels (8) | ~$438 |
| ILB (2 forwarding rules) | ~$36 |
| VPC Connectors (4 e2-micro VMs) | ~$27 |
| Public NAT (hub) | ~$32 |
| VM (e2-micro) | ~$6 |
| **Total** | **~$539/month** |

PoC cost: ~$2.50 per 4-hour session (VPN tunnels dominate at ~$0.60/hr).

# Hybrid NAT Architecture

How Cloud Run services in VPC-2 reach a webserver in VPC-1 across overlapping IP ranges using Hybrid NAT.

## The Problem

VPC-1 and VPC-2 both contain Class E subnets with identical CIDR ranges (`240.0.0.0/8`, `241.0.0.0/8`, `242.0.0.0/8`). Cloud Run services use Direct VPC egress into these overlapping subnets. Because the ranges overlap, standard VPC peering won't work — GCP rejects peering when subnets conflict.

The proxy Cloud Run service (`cr-proxy-v2`) in VPC-2 needs to reach the nginx webserver (`nat-poc-webserver`) in VPC-1's compute subnet (`10.2.0.0/28`).

## Solution Overview

Hybrid NAT combines two GCP features:

1. **HA VPN** — provides an encrypted tunnel between VPC-1 and VPC-2, with BGP exchanging only the non-overlapping routes
2. **Private NAT (Hybrid)** — translates the Cloud Run service's source IP (in an overlapping Class E range) to a dedicated NAT range before it crosses the VPN

## Traffic Flow

```
cr-proxy-v2 (Cloud Run, VPC-2)
  Direct VPC egress into class-e-240-vpc-2 (240.0.0.0/8)
  Source IP: 240.x.x.x
  Destination: 10.2.0.x (webserver in VPC-1)
       │
       ▼
Hybrid NAT (nat-router-vpc2 / hybrid-nat-vpc2)
  Matches: nexthop.is_hybrid (route to 10.2.0.0/28 learned via VPN)
  Rewrites source: 240.x.x.x → 172.16.0.x (pnat-subnet-vpc2)
       │
       ▼
HA VPN tunnel (vpn-gw-vpc2 → vpn-gw-vpc1)
  Encrypted transit between VPCs
       │
       ▼
nat-poc-webserver (Compute, VPC-1)
  IP: 10.2.0.x on compute-subnet
  Sees source: 172.16.0.x
  Responds to 172.16.0.x
       │
       ▼
Return path: VPC-1 routes 172.16.0.0/24 back via VPN
  (VPC-2 advertises this range via BGP)
       │
       ▼
Hybrid NAT translates destination back to 240.x.x.x
  Response delivered to Cloud Run instance
```

## Components

### VPN Layer

| Component | VPC | Purpose |
|---|---|---|
| `vpn-gw-vpc1` | vpc-1 | HA VPN gateway (2 interfaces) |
| `vpn-gw-vpc2` | vpc-2 | HA VPN gateway (2 interfaces) |
| `vpn-router-vpc1` | vpc-1 | Cloud Router, ASN 65001, handles BGP |
| `vpn-router-vpc2` | vpc-2 | Cloud Router, ASN 65002, handles BGP |
| `vpn-tunnel-vpc1-if0/if1` | vpc-1 | VPN tunnels to vpc-2 (both HA interfaces) |
| `vpn-tunnel-vpc2-if0/if1` | vpc-2 | VPN tunnels to vpc-1 (both HA interfaces) |

### NAT Layer

| Component | VPC | Purpose |
|---|---|---|
| `pnat-subnet-vpc2` | vpc-2 | `172.16.0.0/24`, purpose=PRIVATE_NAT. Provides the translated source IPs. |
| `nat-router-vpc2` | vpc-2 | Dedicated Cloud Router for NAT (cannot share with VPN router) |
| `hybrid-nat-vpc2` | vpc-2 | Private NAT gateway, type=PRIVATE. NATs traffic from Class E subnets. |
| NAT rule 100 | vpc-2 | Match expression: `nexthop.is_hybrid`. SNAT to `pnat-subnet-vpc2`. |

### Firewall

| Rule | VPC | Purpose |
|---|---|---|
| `allow-hybrid-nat-ingress-vpc1` | vpc-1 | Allows inbound TCP/UDP/ICMP from `172.16.0.0/24` (NATted traffic) |

## BGP Route Advertisements

Only non-overlapping ranges are advertised. The overlapping Class E subnets are never exchanged.

**vpn-router-vpc1 advertises to VPC-2:**
- `10.2.0.0/28` — compute subnet (where the webserver lives)
- `10.0.0.0/28` — routable subnet

**vpn-router-vpc2 advertises to VPC-1:**
- `10.1.0.0/28` — routable subnet
- `172.16.0.0/24` — PRIVATE_NAT subnet (so return traffic routes back via VPN)

## Why This Works

1. Cloud Run's Direct VPC egress places the service's outbound traffic into VPC-2's Class E subnet (e.g., `240.0.0.0/8`) with a source IP in that range.
2. The destination `10.2.0.0/28` was learned via BGP over the VPN tunnel, so its next hop is "hybrid" (`nexthop.is_hybrid` matches).
3. Hybrid NAT intercepts the packet and rewrites the source from `240.x.x.x` to `172.16.0.x`.
4. The packet traverses the HA VPN tunnel to VPC-1.
5. The webserver receives the request from `172.16.0.x` and responds.
6. VPC-1 routes the response to `172.16.0.0/24` back via the VPN (learned from VPC-2's BGP advertisements).
7. Hybrid NAT translates the destination back, delivering the response to the Cloud Run instance.

## Key Constraints

- **Only non-overlapping destinations are reachable.** A Cloud Run service in VPC-2 can reach `10.2.0.0/28` in VPC-1, but cannot reach `240.0.0.0/8` in VPC-1 — that range overlaps with its own VPC.
- **Dedicated NAT router required.** The Cloud Router running Hybrid NAT cannot have VPN tunnels or other NAT configs attached.
- **BGP convergence takes ~60 seconds.** After running the script, wait before testing.

## Subnet Map

```
VPC-1 (vpc-1)
  ├── 240.0.0.0/8   class-e-240-vpc-1  (overlapping, Cloud Run egress)
  ├── 241.0.0.0/8   class-e-241-vpc-1  (overlapping, Cloud Run egress)
  ├── 242.0.0.0/8   class-e-242-vpc-1  (overlapping, Cloud Run egress)
  ├── 10.0.0.0/28   routable-1         (unique, advertised via BGP)
  └── 10.2.0.0/28   compute-subnet     (unique, advertised via BGP)
        ├── nat-poc-vm          (test VM)
        └── nat-poc-webserver   (nginx, target of proxy)

VPC-2 (vpc-2)
  ├── 240.0.0.0/8   class-e-240-vpc-2  (overlapping, Cloud Run egress)
  ├── 241.0.0.0/8   class-e-241-vpc-2  (overlapping, Cloud Run egress)
  ├── 242.0.0.0/8   class-e-242-vpc-2  (overlapping, Cloud Run egress)
  ├── 10.1.0.0/28   routable-2         (unique, advertised via BGP)
  └── 172.16.0.0/24 pnat-subnet-vpc2   (purpose=PRIVATE_NAT, advertised via BGP)
```

## Testing

After running `setup-hybrid-nat.sh`:

1. **Verify VPN tunnels are established:**
   ```bash
   gcloud compute vpn-tunnels list --region=europe-north2 --project=sb-paul-g-workshop
   ```

2. **Verify BGP sessions and learned routes:**
   ```bash
   gcloud compute routers get-status vpn-router-vpc2 --region=europe-north2 --project=sb-paul-g-workshop
   ```
   VPC-2's router should show learned routes for `10.2.0.0/28` and `10.0.0.0/28`.

3. **Invoke the proxy Cloud Run service:**
   The proxy (`cr-proxy-v2`) forwards requests to the webserver's private IP. If Hybrid NAT is working, the request traverses the VPN with source NAT and returns the nginx default page.

4. **Check NAT mappings:**
   ```bash
   gcloud compute routers get-nat-mapping-info nat-router-vpc2 --region=europe-north2 --project=sb-paul-g-workshop
   ```

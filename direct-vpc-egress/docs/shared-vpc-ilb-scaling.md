# Shared VPC ILB Scaling: 500 Projects × 50 Services

## Scenario

- **1 Shared VPC** (single workload spoke)
- **500 service projects** attached to the Shared VPC
- **50 Cloud Run services per project** (25,000 total)
- Each service exposed to the hub via Internal Application Load Balancer
- All ILBs share one proxy-only subnet
- Direct VPC Egress with overlapping Class E IPs

This document compares two architectural options for organising the ILB layer.

## Option A — Decentralised: One ILB Per Project

Each service project owns its entire ILB stack. This is the simplest ownership model — each team manages their own load balancer independently.

### Component ownership

```
Service Project (× 500)
├── Forwarding Rule (1)
├── Target HTTPS Proxy (1)
├── SSL Certificate (1)
├── URL Map (1, with 50 host/path rules)
├── Backend Services (50)
├── Serverless NEGs (50)
└── Cloud Run Services (50)

Host Project (Shared VPC)
├── VPC network
├── Subnets (overlap, routable, proxy-only, pnat)
├── Firewall rules
├── HA VPN gateways & tunnels
└── Cloud Routers + BGP
```

### Component counts

| Component | Per Project | × 500 | Where |
|---|---|---|---|
| Cloud Run Services | 50 | 25,000 | Service project |
| Serverless NEGs | 50 | 25,000 | Service project |
| Backend Services | 50 | 25,000 | Service project |
| URL Maps | 1 | 500 | Service project |
| Target HTTPS Proxies | 1 | 500 | Service project |
| SSL Certificates | 1 | 500 | Service project |
| **Forwarding Rules** | **1** | **500** | **Service project, on shared VPC** |

### Quota analysis

**Per service project** (each of the 500 projects):

| Quota | Default | Need | Status |
|---|---|---|---|
| Regional internal managed backend services | 50 | 50 | **At ceiling — zero headroom** |
| Serverless NEGs (global) | 100 | 50 | OK |
| URL maps (global) | 10 | 1 | OK |
| Target HTTPS proxies | — | 1 | OK |
| Cloud Run services per region | 1,000 | 50 | OK (hard limit, cannot increase) |
| Cloud Run CPU per region | 200 vCPU | Depends | ~4 instances/service at 1 vCPU default |
| Serverless NEG QPS | 5,000 | Depends | Per service project — not pooled |

**Per VPC network** (the Shared VPC — binding constraints):

| Limit / Quota | Default | Need | Headroom | Adjustable? |
|---|---|---|---|---|
| **Regional internal managed FRs per region per network** | **75** | **500** | **-425 (6.7× over)** | **No — system limit** |
| Internal managed FRs per VPC (all regions) | 500 | 500 | 0 | No — system limit |
| Internal managed FRs per peering group | 500 | 500 | 0 | No — system limit |
| Firewall rules | 1,000 | Depends on design | Likely OK | Yes |
| Subnets per network | 300 | ~4 | OK | Yes |

> **Note**: The forwarding rules per region per network metric (`compute.googleapis.com/regional_internal_managed_forwarding_rules_per_region_per_vpc_network`) is classified as a **system limit** in the GCP console (Type: "System limit", Adjustable: "No"). It is **not** a requestable quota — this is a hard ceiling that cannot be raised via support or quota increase requests.

### Verdict

**Architecturally blocked.** The 75 forwarding rules per region per network is a hard system limit, not an adjustable quota. Option A cannot support more than 75 projects with their own ILB on a single Shared VPC in a single region. This is not a matter of requesting an increase — it is a platform constraint.

---

## Option B — Centralised: Shared ILBs with Cross-Project Backends

A small number of "platform" ILBs in a dedicated project, with URL maps that reference backend services in service projects using [cross-project service referencing](https://cloud.google.com/load-balancing/docs/l7-internal/l7-internal-shared-vpc).

### How cross-project service referencing works

GCP allows the frontend and backend of a load balancer to live in **different projects**:

| Component | Location | Constraint |
|---|---|---|
| Cloud Run service | Service project | — |
| Serverless NEG | Service project | **Must be same project as Cloud Run service** |
| Backend service | Service project | **Must be same project as NEG** |
| URL map | Platform project | References backend services via full resource URI |
| Target HTTPS proxy | Platform project | — |
| SSL certificate | Platform project | — |
| Forwarding rule | Platform project | — |

The URL map references backend services cross-project:

```
projects/SERVICE_PROJECT_ID/regions/REGION/backendServices/BACKEND_SERVICE_NAME
```

The service project must grant `roles/compute.loadBalancerServiceUser` to the platform project's LB admin for this to work.

### Component ownership

```
Platform Project (1)
├── Forwarding Rules (13)           ← 25,000 services ÷ 2,000 URL map rules
├── Target HTTPS Proxies (13)
├── SSL Certificates (13 or fewer)
└── URL Maps (13, each with ≤2,000 rules)
      └── each rule → projects/svc-proj-N/regions/R/backendServices/bs-name

Service Project (× 500)
├── Backend Services (50)
├── Serverless NEGs (50)
└── Cloud Run Services (50)

Host Project (Shared VPC)
├── VPC network & subnets
├── Firewall rules
├── HA VPN, Cloud Routers
```

### Component counts

| Component | Count | Where |
|---|---|---|
| Cloud Run Services | 25,000 | 500 service projects (50 each) |
| Serverless NEGs | 25,000 | 500 service projects (50 each) |
| Backend Services | 25,000 | 500 service projects (50 each) |
| URL Maps | **13** | Platform project |
| Target HTTPS Proxies | **13** | Platform project |
| SSL Certificates | **≤13** | Platform project |
| **Forwarding Rules** | **13** | **Platform project** |

### URL map sizing

Each URL map supports up to **2,000 host/path rules**:

```
25,000 services ÷ 2,000 rules per URL map = 13 URL maps (rounded up)
```

Each URL map gets its own forwarding rule + target HTTPS proxy:

```
Forwarding Rule 1 (platform-ilb-01, 10.x.0.1:443)
  → Target HTTPS Proxy 1
    → URL Map 1 (2,000 rules)
        ├→ svc-a.proj-001.internal → projects/proj-001/.../bs-svc-a
        ├→ svc-b.proj-001.internal → projects/proj-001/.../bs-svc-b
        ├→ ...
        └→ svc-z.proj-040.internal → projects/proj-040/.../bs-svc-z

Forwarding Rule 2 (platform-ilb-02, 10.x.0.2:443)
  → URL Map 2 (2,000 rules)
        └→ ... next 2,000 services

... through Forwarding Rule 13
```

### Quota analysis

**Per service project** (each of 500):

| Quota | Default | Need | Status |
|---|---|---|---|
| Regional internal managed backend services | 50 | 50 | **At ceiling — zero headroom** |
| Serverless NEGs (global) | 100 | 50 | OK |
| Cloud Run services per region | 1,000 | 50 | OK |
| Cloud Run CPU per region | 200 vCPU | Depends | Likely needs increase |
| Serverless NEG QPS | 5,000 | Per project — not pooled | OK for most workloads |

**Platform project**:

| Quota | Default | Need | Status |
|---|---|---|---|
| URL maps (global) | 10 | 13 | **Slightly over — request increase** |

**Per VPC network** (system limits — not adjustable):

| Limit | Value | Need | Status |
|---|---|---|---|
| **Regional internal managed FRs per region per network** | **75** | **13** | **OK — 83% headroom** |
| Internal managed FRs per VPC (all regions) | 500 | 13 | OK |
| Firewall rules | 1,000 | Depends | Likely OK |

### Verdict

**Fits within default quotas** for the critical forwarding rules limit. The only default exceeded is URL maps in the platform project (13 vs 10 default) — a routine quota increase. The forwarding rule bottleneck is eliminated entirely.

---

## Side-by-Side Comparison

| Dimension | Option A (Decentralised) | Option B (Centralised) |
|---|---|---|
| **Forwarding rules on VPC** | **500** (6.7× over hard limit of 75) | **13** (within limit) |
| Backend services per project | 50 (at default ceiling) | 50 (at default ceiling) |
| Serverless NEG QPS | Per service project (distributed) | Per service project (distributed) |
| URL maps | 500 (1/project, within default) | 13 (platform project, minor increase) |
| **Limit/quota issues** | **Blocked — hard system limit** | **Minor** (URL maps: 10→13, adjustable) |
| Ownership model | Self-service per project | Platform team manages ILB frontend |
| Onboarding a new project | Project creates its own ILB stack | Platform team adds URL map rules + grants IAM |
| Blast radius of misconfiguration | Contained to one project's ILB | URL map change can affect routing for many projects |
| SSL certificate management | Each project manages its own cert | Platform team manages ≤13 certs |
| Independent scaling | Each project scales independently | Shared URL maps — may need to rebalance |
| Hub route advertisements | 1 VIP per project (500 IPs to advertise) | 13 VIPs to advertise |

## Subnet Sizing (Both Options)

The subnet requirements are the same regardless of ILB ownership model:

| Subnet | Purpose | PoC | At Scale (500 × 50) | Recommended |
|---|---|---|---|---|
| **Overlap** | Cloud Run egress | `/20` (4K IPs) | 25K services × N instances × 2 IPs | **`/12`** (1M IPs) |
| **Routable** | ILB forwarding rule VIPs | `/22` (1K IPs) | 500 VIPs (Option A) or 13 (Option B) | **`/22`** (sufficient for both) |
| **Proxy-only** | Envoy proxies (shared pool) | `/18` (16K IPs) | 500 ILBs under load (Option A) or 13 (Option B) | **`/16`** (Option A) or **`/18`** OK (Option B) |
| **PNAT** | Hybrid NAT (spoke→hub) | `/24` (256 IPs) | 25K services NATing outbound | **`/18`** (16K IPs) |

Notes:
- **Overlap** and **proxy-only** use Class E space — zero routable address cost.
- **Routable** consumes real RFC 1918 space advertised via BGP.
- **PNAT** consumes real RFC 1918 space; NAT port exhaustion is the real constraint (see [scaling-analysis.md](scaling-analysis.md) §2.1).

## Serverless NEG QPS — Corrected Analysis

The [main scaling analysis](scaling-analysis.md) (§2.3) assumed ILB resources live in the host project, pooling all serverless NEG QPS into one 5,000 QPS bucket. This is **incorrect for both options** in a Shared VPC model where service projects own the backend services and NEGs.

**Corrected**: The 5,000 QPS limit applies **per project per region** where the serverless NEG is created. Since NEGs live in the service projects in both options:

| Option | QPS pool | Aggregate QPS capacity |
|---|---|---|
| A (Decentralised) | 5,000 per service project | 500 × 5,000 = **2.5M QPS** |
| B (Centralised) | 5,000 per service project | 500 × 5,000 = **2.5M QPS** |

This removes serverless NEG QPS as a scaling concern at this scale.

## IAM Requirements (Option B Only)

For cross-project backend service references, each service project must grant:

```
roles/compute.loadBalancerServiceUser
```

to the platform project's Load Balancer Admin identity. This can be scoped to:

- **Project level**: all backend services in the service project (simpler)
- **Resource level**: individual backend services (more restrictive)

## Recommendation

**Option B (Centralised) is the only viable option** at 500 projects:

1. **Option A is blocked**: The 75 forwarding rules per region per network is a hard system limit (not adjustable). Option A is architecturally impossible beyond 75 projects per spoke.
2. **Option B fits**: 13 forwarding rules is well within the 75 limit, leaving room for growth.
3. **Hub simplicity**: 13 VIPs to advertise via BGP, not 500.
4. **Proxy-only efficiency**: 13 ILBs share the proxy pool more efficiently than 500.
5. **Operational trade-off**: Requires a platform team to manage the ILB frontend, but this is typical in enterprise Shared VPC deployments where networking is already centralised.

The main risk is the **backend services per project** quota (50 default, need exactly 50). Request an increase to at least 75 per service project for growth headroom.

For projects needing full independence (e.g., separate SLAs, independent certificate management), a **hybrid model** works: most projects route through the shared ILBs (Option B), while a few high-priority projects get their own dedicated ILB (Option A) — consuming forwarding rules from the hard limit of 75 per spoke.

## References

| Topic | URL |
|---|---|
| Cross-project service referencing (internal ALB) | https://cloud.google.com/load-balancing/docs/l7-internal/l7-internal-shared-vpc |
| Serverless NEG concepts & limits | https://cloud.google.com/load-balancing/docs/negs/serverless-neg-concepts |
| Load Balancing quotas | https://cloud.google.com/load-balancing/docs/quotas |
| URL map limits | https://cloud.google.com/load-balancing/docs/quotas#url_maps |
| Shared VPC overview | https://cloud.google.com/vpc/docs/shared-vpc |
| `roles/compute.loadBalancerServiceUser` | https://cloud.google.com/compute/docs/access/iam#compute.loadBalancerServiceUser |

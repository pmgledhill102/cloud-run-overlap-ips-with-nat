# Spoke Architecture Scaling Analysis

## 1. Executive Summary

This document analyses what happens when the PoC's hub-spoke architecture is scaled to a production Shared VPC model: many GCP projects sharing a single spoke VPC, each with many Cloud Run services and jobs.

**Target scenario**: 50 projects sharing one spoke VPC, each with 20 Cloud Run services = **1,000 services per spoke**, with ~5,000 concurrent instances at peak.

**Key findings**:

- **BGP route prefixes on the hub** are the first soft limit to hit. At 2 routes per spoke, the default quota of 250 is exhausted at **125 spokes**. Requestable, but the hard ceiling is the 128 BGP peers per Cloud Router × 5 Cloud Routers = **640 peers**, capping at ~160–320 spokes depending on tunnels per spoke.
- **Serverless NEG QPS** (5,000/project/region) is the binding constraint for hub→spoke traffic volume. In Shared VPC, all ILB traffic counts against the host project's single pool.
- **ILB forwarding rules** become a bottleneck at ~50–100 services per spoke under a 1-FR-per-service model, but URL-map routing eliminates this entirely.
- **PNAT capacity**, **VPN throughput**, **proxy-only subnet**, and **Cloud Run IP space** are all comfortable at the target scale with modest subnet expansions.

## 2. Scaling Dimensions

### 2.1 Spoke→Hub: PNAT Subnet & NAT Port Allocation

Cloud Run instances egressing to the hub via Hybrid NAT have their overlapping `240.x.x.x` addresses translated to IPs from the PNAT subnet.

**GCP limit**: Private NAT port allocation formula:

```
max_endpoints = floor( usable_IPs × 64,512 / (min_ports_per_VM × 2) )
```

The `× 2` is specific to Private NAT — Google allocates twice the minimum ports per VM for reliability. `usable_IPs = 2^(32 - prefix_length) - 4`.

| Setting | PoC (`/24`) | Production (`/20`) |
|---|---|---|
| Usable IPs | 252 | 4,092 |
| At 64 ports/VM (static) | ~127,000 endpoints | ~2.07M endpoints |
| At 1,024 ports/VM | ~7,937 endpoints | ~128,888 endpoints |

Private NAT defaults to **dynamic port allocation** (min 32, max 65,536), which is more efficient than static allocation for bursty workloads.

**Connection tracking**: 65,535 entries per VM (hard). Private NAT additionally caps at 64,000 simultaneous connections per endpoint. Closed TCP connections occupy an entry for 120 seconds (TIME_WAIT). For typical Cloud Run request/response patterns (short-lived connections), this is unlikely to be a bottleneck.

**PoC sizing**: `/24` = 252 usable IPs. At default dynamic allocation, supports well over 5,000 instances.

**Verdict**: Not a binding constraint. Expand to `/20` for production headroom; even `/24` handles the target scenario comfortably.

### 2.2 Hub→Spoke: ILB Forwarding Rules & Routable IP Space

Each Cloud Run service exposed to the hub needs a path through the ILB. The PoC uses one forwarding rule per service.

**GCP limits**:

| Limit | Value | Type |
|---|---|---|
| Forwarding rules per VPC per region | Project-specific quota (check console) | Soft — requestable |
| Forwarding rules sharing one IP | 10 | Hard |

**PoC sizing**: Routable subnet `/28` = 12 usable IPs × 10 FRs/IP = **120 forwarding rules max**. With 2 services in the PoC, this is ample.

**At scale**: 1,000 services with 1 FR each requires 1,000 forwarding rules and at least 100 IPs (10 FRs per IP). The `/28` is exhausted at ~120 services.

**Key mitigation — URL-map routing**: Instead of 1 FR per service, use a **single ILB per spoke** with host/path-based routing in the URL map to direct traffic to different backend services (each backed by a serverless NEG). This reduces the forwarding rule count from N to **1 per spoke**, regardless of how many services exist.

```
Single FR → URL map → host: svc-a.spoke-1.internal → backend-svc-a → NEG-a → cr-svc-a
                     → host: svc-b.spoke-1.internal → backend-svc-b → NEG-b → cr-svc-b
                     → ...
```

With URL-map routing, even a `/28` routable subnet is sufficient for many spokes. For production, a `/22` (1,022 usable IPs) provides ample headroom.

**Verdict**: Binding at ~50–120 services with 1-FR-per-service model. URL-map routing eliminates this constraint entirely.

### 2.3 Hub→Spoke: Serverless NEG QPS

Serverless NEGs have a **per-project, per-region** QPS limit that is aggregated across all regional load balancers.

**GCP limit**: **5,000 QPS per project per region** across all serverless NEGs. Requestable via support.

**Critical Shared VPC implication**: ILB resources (forwarding rules, backend services, NEGs) live in the **host project**. All hub→spoke traffic through the ILB counts against the **host project's single 5,000 QPS pool** — not per service project.

| Scale | Aggregate QPS | vs 5K limit |
|---|---|---|
| 10 services × 50 QPS | 500 | OK |
| 100 services × 50 QPS | 5,000 | At limit |
| 100 services × 100 QPS | 10,000 | 2× over |
| 1,000 services × 50 QPS | 50,000 | 10× over |

**Mitigations**:
1. **Request quota increase** early — this is the most direct fix.
2. **Private Service Connect (PSC)**: Publish Cloud Run services as PSC service attachments. Consumers in the hub connect via PSC endpoints, bypassing serverless NEG entirely. Each PSC endpoint has its own connection and is not subject to the aggregated QPS limit.
3. **Global external Application Load Balancer**: The 5,000 QPS limit applies only to regional LBs, not global ones. If the hub can reach a global LB endpoint, this limit doesn't apply (though this changes the network topology).

**Verdict**: Binding at modest traffic. Request increase from the outset and evaluate PSC for high-scale deployments.

### 2.4 Hub→Spoke: Proxy-Only Subnet Capacity

The regional internal Application Load Balancer provisions Envoy proxies from the proxy-only subnet. All regional Envoy-based LBs in the same VPC and region **share one proxy pool**.

**GCP capacity per proxy**:

| Metric | Per proxy |
|---|---|
| Requests/sec (no logging) | 1,400 |
| Requests/sec (100% logging) | 700 |
| New HTTP connections/sec | 600 |
| Active connections | 3,000 |
| Bandwidth | 18 MB/s |

Proxies auto-scale based on a 10-minute measurement window. Pre-warming available via support for bursts above 100K QPS.

| Subnet size | Addresses | QPS capacity (@ 1,400 RPS/proxy) |
|---|---|---|
| `/26` (PoC) | 64 | ~89,600 |
| `/23` (recommended) | 512 | ~716,800 |
| `/20` | 4,096 | ~5,734,400 |

**At scale**: 1,000 services × 500 QPS = 500K QPS → needs ~358 proxies → needs a `/23` (512 addresses).

The proxy-only subnet uses Class E space (`241.0.0.0/x`) so expanding it consumes zero routable address space.

**Verdict**: Expand from `/26` to `/23` for production. Straightforward change with no address scarcity concern.

### 2.5 VPN Throughput

HA VPN tunnels are the data plane between hub and spokes.

**GCP limits per tunnel**:

| Metric | Limit | Type |
|---|---|---|
| Packets/sec (ingress + egress combined) | 250,000 | Hard |
| Bandwidth | 1–3 Gbps (packet-size dependent) | Hard |

An HA VPN gateway has 2 interfaces. Between two GCP HA VPN gateways (GCP-to-GCP), you get **2 tunnels** per gateway pair. ECMP load-balances across tunnels sharing the same Cloud Router.

| Configuration | Tunnels | Aggregate bandwidth |
|---|---|---|
| PoC (1 gateway pair/spoke) | 4 (2 per direction) | 4–12 Gbps |
| 2 gateway pairs/spoke | 8 (4 per direction) | 8–24 Gbps |
| 4 gateway pairs/spoke | 16 (8 per direction) | 16–48 Gbps |

**At scale**: 1,000 services × 10 Mbps average = 10 Gbps → borderline on 4 tunnels with small packets. Add a second gateway pair for headroom.

**Cost**: Each additional gateway pair adds ~$110/month (2 additional tunnels × $0.075/hr × 730 hrs).

**Beyond 50 Gbps**: Consider Cloud Interconnect (up to 100 Gbps per VLAN attachment). HA VPN can also run over Cloud Interconnect for encrypted high-bandwidth links.

**Verdict**: Adequate for moderate traffic with the PoC's 4 tunnels. Add gateway pairs as traffic grows. Each pair is cheap (~$110/month).

### 2.6 BGP Routes on Hub — THE BINDING CONSTRAINT

The hub's Cloud Router(s) learn routes from every spoke via BGP. This is where the architecture hits hard limits.

**GCP limits**:

| Limit | Value | Type |
|---|---|---|
| Unique dynamic route prefixes (from own region) per region per VPC | **250** (default) | Soft — requestable via support |
| BGP peers per Cloud Router | **128** | Hard |
| Cloud Routers per VPC per region | **5** | Hard |
| Prefixes accepted from a single BGP peer | 5,000 | Hard (session reset if exceeded) |
| Custom advertised routes per BGP session | 200 | Hard |

**Route consumption**: Each spoke advertises **2 routes** to the hub (routable `/28` + PNAT `/24`). The hub learns these as dynamic route prefixes.

**Soft limit — route prefixes**:
- Default quota: 250 unique prefixes
- At 2 routes/spoke: **125 spokes** exhaust the default quota
- Requestable increase (contact support; no published maximum)

**Hard limit — BGP peers**:
- Each spoke needs BGP peers on the hub Cloud Router(s)
- With 1 gateway pair/spoke (PoC): **2 peers per spoke** on the hub
  - 5 routers × 128 peers / 2 = **320 spokes max**
- With 2 gateway pairs/spoke (production HA): **4 peers per spoke**
  - 5 routers × 128 peers / 4 = **160 spokes max**

**This is the ultimate hard ceiling**: 5 Cloud Routers × 128 peers = **640 BGP peers** on the hub, which cannot be increased. At 2–4 peers per spoke, this caps the architecture at **160–320 spokes per hub VPC**.

**Beyond the ceiling**: A **multi-hub architecture** is required, where traffic is distributed across multiple hub VPCs (each with its own set of 5 Cloud Routers). Alternatively, Network Connectivity Center (NCC) may simplify route exchange at scale.

**Verdict**: Route prefix quota (250, soft) is the first limit to hit at 125 spokes. BGP peer count (640, hard) is the absolute ceiling at 160–320 spokes. Plan hub router topology from the start.

### 2.7 Cloud Run IP Consumption in Overlap Subnet

Cloud Run services with Direct VPC egress consume IPs from the subnet they are deployed into.

**GCP behaviour**:

| Aspect | Detail |
|---|---|
| IPs per instance | **2×** the number of instances |
| IP reservation blocks | Allocated in blocks of **16** (/28) for fast scale-up |
| IP hold after scale-down | Up to **20 minutes** |
| IP hold after job task completion | **7 minutes** |
| Minimum subnet size | `/26` |

**Scaling math**:

| Scale | Instances | IPs needed (2×) | % of `/8` |
|---|---|---|---|
| PoC (2 services) | 10 | 20 | 0.0001% |
| 100 services × 50 instances | 5,000 | 10,000 | 0.06% |
| 1,000 services × 100 instances | 100,000 | 200,000 | 1.2% |
| Revision rollover (2× above) | 200,000 | 400,000 | 2.4% |

The overlapping `/8` subnet (`240.0.0.0/8`) provides **16,777,216 addresses** — 16.7M. Even the most aggressive scaling scenario uses a small fraction.

**Per-project limits**:

| Resource | Limit | Requestable |
|---|---|---|
| Max instances per revision (with Direct VPC egress) | 100–200 (region-dependent) | Yes |
| Services per project per region | 1,000 | No |
| Jobs per project per region | 1,000 | No |

**Verdict**: Not a constraint. The `/8` is enormous. Per-revision instance limits (100–200) are the more relevant bottleneck but are requestable.

### 2.8 Per-Project vs Per-VPC Quotas in Shared VPC

In a Shared VPC model, some quotas are scoped to the **host project** (shared pool) while others are scoped to each **service project** (independent). Understanding the scope is critical for capacity planning.

| Resource | Quota Scope | Effect at Scale |
|---|---|---|
| Cloud Run services | Per service project per region | 1,000/project. 50 projects = 50,000 possible |
| Cloud Run instances | Per service project | Independent compute quota per project |
| Cloud Run Direct VPC egress instances | Per service project (requestable) | 100–200 default per revision per project |
| ILB forwarding rules | Per VPC per region (host project) | Shared pool across all projects in the spoke |
| Serverless NEG QPS | Per host project per region | All LB traffic counts against host's 5K limit |
| VPN tunnels/gateways | Per host project | Single pool |
| Cloud Routers | Per VPC per region (max 5) | Hard limit, shared across all traffic |
| Dynamic route prefixes | Per VPC per region (250 default) | Shared across all spokes on the hub |
| Firewall rules | Per host project | 1,000 default (requestable). Shared |
| Subnet IP addresses | Per VPC | Shared. The `/8` overlap subnet is consumed by all projects' Cloud Run instances |

**Key insight**: The resources that become shared bottlenecks in Shared VPC are: serverless NEG QPS, ILB forwarding rules, and firewall rules — all scoped to the host project or host VPC.

### 2.9 Cost Scaling

VPN tunnels dominate the connectivity cost. All other components are relatively inexpensive.

**Per-spoke costs** (1 gateway pair = 4 tunnels):

| Component | Monthly cost |
|---|---|
| HA VPN tunnels (4) | $219 |
| ILB proxy (auto-scaled, minimal) | ~$18 |
| Cloud NAT (Hybrid NAT gateway) | ~$32 |
| Cloud Routers | Free |
| **Total per spoke** | **~$269** |

**Aggregate costs**:

| Spokes | VPN cost | Total connectivity |
|---|---|---|
| 2 (PoC) | $438 | ~$538 |
| 10 | $2,190 | ~$2,690 |
| 50 | $10,950 | ~$13,450 |
| 100 | $21,900 | ~$26,900 |

Adding a second gateway pair per spoke for bandwidth adds ~$110/month per spoke.

**Data transfer**: VPN tunnel data transfer within the same region is free. Cross-region transfer is charged at standard egress rates.

**Cost optimization**: For PoC/dev environments, tear down VPN tunnels when not in use. 8 tunnels × $0.075/hr = **$0.60/hour** in the current PoC.

## 3. Summary Table

| # | Dimension | GCP Limit | PoC Value | Hits Limit At | Hard/Soft | Mitigation |
|---|---|---|---|---|---|---|
| 1 | PNAT port capacity | `usable_IPs × 64,512 / (min_ports × 2)` | `/24` → ~127K endpoints | Well beyond target | N/A | Expand to `/20` for headroom |
| 2 | ILB forwarding rules | Project-specific quota; 10/IP hard | `/28` = 12 IPs → 120 FRs | ~50–120 services (1-FR model) | Soft (quota) / Hard (10/IP) | URL-map routing → 1 FR/spoke |
| 3 | Serverless NEG QPS | 5,000/project/region | 2 services, minimal QPS | ~100 services × 50 QPS | Soft — requestable | Request increase; consider PSC |
| 4 | Proxy-only subnet | Auto-scaled; 1,400 RPS/proxy | `/26` = 64 proxies → 90K QPS | ~500K QPS needs `/23` | Subnet size | Expand to `/23` (Class E, free) |
| 5 | VPN throughput | 250K pps / 1–3 Gbps per tunnel | 4 tunnels → 4–12 Gbps | ~10 Gbps (borderline on 4) | Hard per tunnel | Add gateway pairs ($110/mo each) |
| 6 | BGP route prefixes (hub) | 250/region/VPC (default) | 4 routes (2 spokes × 2) | **125 spokes** | Soft — requestable | Request increase early |
| 7 | BGP peers (hub) | 128/router × 5 routers = 640 | 4 peers (2 spokes × 2) | **160–320 spokes** | **Hard** | Multi-hub architecture |
| 8 | Cloud Run IPs (overlap) | 2× per instance, `/8` = 16.7M | ~20 IPs | >8M instances | N/A | Not a constraint |
| 9 | Cloud Run services | 1,000/project/region | 2 services | 1,000 per project | Hard | Add projects |
| 10 | CR max instances (VPC egress) | 100–200/revision | 5 | 100–200 per revision | Soft — requestable | Request quota increase |

## 4. Recommendations

### Immediate (before production)

1. **URL-map routing**: Deploy a single ILB per spoke with host/path-based routing to multiple backend services. This eliminates the forwarding rule bottleneck entirely and simplifies the hub's route table (one ILB IP per spoke instead of many).

2. **Expand subnets**: Size subnets for production from the start.

   | Subnet | PoC | Production | Rationale |
   |---|---|---|---|
   | Routable (ILB) | `/28` (12 IPs) | `/22` (1,022 IPs) | Headroom for multiple FRs if needed |
   | PNAT (Hybrid NAT) | `/24` (252 IPs) | `/20` (4,092 IPs) | 10× headroom for NAT port allocation |
   | Proxy-only | `/26` (64 addrs) | `/23` (512 addrs) | Supports ~700K QPS; uses Class E space |
   | Overlap (Cloud Run) | `/8` | `/8` | Already enormous, no change needed |

3. **Request serverless NEG QPS increase** for the host project before deploying more than a handful of services behind the ILB.

4. **Hub router topology**: Deploy **multiple Cloud Routers** on the hub from the start. Distribute spoke VPN tunnels across routers to avoid concentrating BGP peers on a single router. This extends the usable peer capacity and provides resilience.

### Medium-term (scaling beyond ~50 spokes)

5. **Evaluate Private Service Connect (PSC)**: PSC avoids both the serverless NEG QPS limit and the forwarding rule quota compounding. Cloud Run services publish as PSC service attachments; hub consumers connect via PSC endpoints. Each endpoint is independent — no shared QPS pool.

6. **Evaluate Network Connectivity Center (NCC)**: NCC's hub-and-spoke model may simplify route exchange at scale, abstracting away individual VPN tunnel BGP sessions. Evaluate whether NCC changes the BGP peer ceiling.

7. **Address plan for route summarization**: Assign contiguous CIDR blocks for routable and PNAT subnets across spokes so they can be summarized into fewer route prefixes. For example, 64 spokes each with a `/28` routable subnet can be summarized as a single `/22` if they are contiguous, reducing 64 learned routes to 1.

### Ongoing

8. **Monitoring and alerts**: Set up alerts on:
   - `router.googleapis.com/best_received_routes_count` — BGP route prefix usage vs quota
   - `nat.googleapis.com/nat_allocation_failed` — NAT port exhaustion
   - Cloud Monitoring → Serverless NEG QPS dashboard (custom metric)
   - Cloud Run instance count and IP consumption per subnet

## 5. References

| Topic | URL |
|---|---|
| Cloud Router quotas and limits | https://cloud.google.com/network-connectivity/docs/router/quotas |
| Cloud NAT quotas | https://cloud.google.com/nat/quota |
| Cloud NAT port allocation | https://cloud.google.com/nat/docs/ports-and-addresses |
| Private NAT overview | https://cloud.google.com/nat/docs/private-nat |
| Hybrid NAT overview | https://cloud.google.com/nat/docs/about-hybrid-nat |
| NAT timeout tuning | https://cloud.google.com/nat/docs/tune-nat-configuration |
| Load Balancing quotas | https://cloud.google.com/load-balancing/docs/quotas |
| Serverless NEG concepts & limits | https://cloud.google.com/load-balancing/docs/negs/serverless-neg-concepts |
| Proxy-only subnet sizing | https://cloud.google.com/load-balancing/docs/proxy-only-subnets |
| HA VPN quotas | https://cloud.google.com/network-connectivity/docs/vpn/quotas |
| HA VPN bandwidth topologies | https://cloud.google.com/network-connectivity/docs/vpn/concepts/topologies-increase-bandwidth |
| Cloud Run quotas | https://cloud.google.com/run/quotas |
| Cloud Run max instances | https://cloud.google.com/run/docs/configuring/max-instances |
| Cloud Run Direct VPC egress | https://cloud.google.com/run/docs/configuring/vpc-direct-vpc |
| Cloud Run Shared VPC Direct VPC egress | https://cloud.google.com/run/docs/configuring/shared-vpc-direct-vpc |

# Approach Comparison: Direct VPC Egress vs VPC Connector

## Summary

Both approaches solve the same problem: enabling Cloud Run services across separate spoke VPCs to communicate bidirectionally with a central hub, even when spokes would otherwise have overlapping IP ranges.

They differ in **how Cloud Run connects to the VPC** — and this one difference cascades into significantly different architectures.

## Side-by-Side

| | Direct VPC Egress | VPC Connector |
|---|---|---|
| **Cloud Run networking** | `--network`/`--subnet` | `--vpc-connector` |
| **How Cloud Run connects** | Deploys directly into VPC subnet | Connects through connector VMs |
| **Cloud Run egress IP** | From VPC subnet (e.g., `240.x.x.x`) | From connector VM (e.g., `10.10.x.x`) |
| **Overlapping subnet needed?** | Yes (`240.0.0.0/20`) | No |
| **Hybrid NAT needed?** | Yes (SNAT `240.x` → `172.16.x`) | No |
| **PNAT subnet needed?** | Yes (`172.16.x.0/24`) | No |
| **Subnets per spoke** | 4 | 3 |
| **Total subnets (2 spokes)** | 10 | 7 |
| **NAT routers per spoke** | 1 (Hybrid NAT) | 0 |
| **BGP routes per spoke** | 2 (routable + pnat) | 2 (connector + routable) |
| **VPN tunnels** | 8 (4 per spoke) | 8 (4 per spoke) |
| **Additional VMs** | 0 | 2-3 per spoke (connector) |

## Complexity

| Aspect | Direct VPC Egress | VPC Connector |
|---|---|---|
| Setup scripts | More complex (Hybrid NAT config) | Simpler (no NAT config) |
| Debugging | NAT translation adds indirection | Connector VM is the only hop |
| IP addressing | Need overlapping + PNAT ranges | All IPs unique and routable |
| Teardown | Must wait for Cloud Run IP release | Connector deletion is cleaner |

**Verdict**: VPC Connector is architecturally simpler because the connector itself acts as the NAT boundary, eliminating an entire layer of infrastructure.

## Cost (2 spokes, always-on)

| Resource | Direct VPC Egress | VPC Connector |
|---|---|---|
| HA VPN tunnels (8) | $438 | $438 |
| ILB (2 forwarding rules) | $36 | $36 |
| Cloud NAT (2 Hybrid + 1 Public) | $32 | $32 (Public only) |
| VPC Connectors (4 e2-micro) | — | $27 |
| VM (e2-micro) | $6 | $6 |
| **Total** | **~$512/month** | **~$539/month** |

Cost difference is marginal (~$27/month for connector VMs). VPN tunnels dominate both.

## Throughput

| | Direct VPC Egress | VPC Connector |
|---|---|---|
| Max throughput | VPN-limited (~3 Gbps/tunnel) | Connector-limited (~200 Mbps/e2-micro) |
| Scaling throughput | Add VPN gateway pairs | Upgrade connector machine type |
| Bottleneck | VPN tunnel bandwidth | Connector VM bandwidth |

**Verdict**: Direct VPC Egress has higher throughput ceiling. VPC Connector tops out at ~200 Mbps per e2-micro (upgradeable to e2-standard-4 for ~1 Gbps, but still connector-limited).

## Google's Recommendation

- **Direct VPC Egress**: Recommended for new deployments (GA, no VM overhead)
- **VPC Connector**: Still fully supported but considered legacy for new projects

## When to Use Which

### Choose Direct VPC Egress when:
- Starting a new project (Google's recommendation)
- High throughput requirements
- Want to avoid connector VM costs
- Need fine-grained control over Cloud Run IP assignment

### Choose VPC Connector when:
- Need simpler networking (no NAT configuration)
- All IPs must be unique and routable (compliance/auditability)
- Throughput requirements are modest (< 200 Mbps)
- Already have VPC Connector infrastructure

## Coexistence

Both approaches can coexist on the same hub VPC. The scripts are designed for this:
- Shared hub resources (VPC, VM, Artifact Registry) are managed by `shared/`
- Each approach uses distinct spoke VPC names (`spoke-1/2` vs `spoke-c1/c2`)
- Each approach uses distinct ASNs and BGP link-local IPs to avoid conflicts
- Hub teardown checks for remaining spoke VPCs before deleting shared resources

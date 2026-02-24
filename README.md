# Cloud Run Overlapping IPs with Hub-Spoke NAT

GCP proof-of-concept demonstrating how Cloud Run services can use **overlapping IP ranges** (Class E `240.0.0.0/8`) across separate VPCs, with bidirectional communication through a central hub using HA VPN, Hybrid NAT, and Internal Load Balancers.

## Architecture

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

**Flow A — Spoke → Hub:** Cloud Run Job (240.x.x.x) → Hybrid NAT (→172.16.x.x) → HA VPN → VM (10.0.0.x)

**Flow B — Hub → Spoke:** VM (10.0.0.x) → HA VPN → ILB (10.x.0.x) → serverless NEG → Cloud Run service

See [docs/architecture.md](docs/architecture.md) for full details on subnets, BGP, and cost estimates.

## Quick Start

```bash
# 1. Create service account and bind IAM roles (run as Owner/IAM Admin)
./setup-iam.sh

# 2. Impersonate the service account
gcloud config set auth/impersonate_service_account cloud-run-nat-poc@PROJECT_ID.iam.gserviceaccount.com

# 3. Create base infrastructure (VPCs, subnets, firewall, VM, Cloud Run)
./setup-infra.sh

# 4. Create connectivity (HA VPN, BGP, Hybrid NAT, Public NAT, ILB)
./setup-connectivity.sh

# 5. Wait ~60s for BGP convergence, then test
./test.sh

# 6. Tear down when done (VPN costs ~$0.60/hr)
./teardown.sh
```

## Scripts

| Script | Purpose |
|---|---|
| `setup-iam.sh` | Service account, IAM roles, API enablement |
| `setup-infra.sh` | VPCs, subnets, firewall, Artifact Registry, container images, VM, Cloud Run services + jobs |
| `setup-connectivity.sh` | HA VPN, BGP, Hybrid NAT, Public NAT, ILB + serverless NEG |
| `teardown.sh` | Complete teardown of all resources in dependency order |
| `test.sh` | Exercises both traffic flows (spoke→hub via jobs, hub→spoke via ILB) |

All scripts default `PROJECT_ID` to `sb-paul-g-workshop`. Region is `europe-north2`. All scripts are idempotent.

## Resources Created

- **3 VPCs** — `hub`, `spoke-1`, `spoke-2`
- **9 subnets** — compute, overlap (x2), routable (x2), proxy-only (x2), private NAT (x2)
- **1 VM** — `vm-hub` (e2-micro, python3 HTTP server, private IP only)
- **2 Cloud Run services** — `cr-spoke-1`, `cr-spoke-2` (Go HTTP server on overlapping subnets)
- **2 Cloud Run jobs** — `job-spoke-1`, `job-spoke-2` (test clients for spoke→hub flow)
- **8 HA VPN tunnels** — 4 per spoke (2 interfaces × 2 directions)
- **6 Cloud Routers** — 3 for VPN (hub + 2 spokes), 3 for NAT (hub + 2 spokes)
- **2 Hybrid NAT gateways** — one per spoke, SNAT overlapping → routable
- **1 Public NAT gateway** — hub, internet access for VM
- **2 Internal Load Balancers** — serverless NEG → Cloud Run, one per spoke

## Cost

~$0.60/hr when running (VPN tunnels dominate). Tear down after each test session.

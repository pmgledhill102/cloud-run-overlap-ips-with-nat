# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

GCP proof-of-concept demonstrating how Cloud Run services can use overlapping IP ranges (Class E `240.0.0.0/8`) across different VPCs, with a hub-spoke architecture that enables bidirectional communication via HA VPN, Hybrid NAT, and Internal Load Balancers.

## Scripts

- **`setup-iam.sh`** — Creates service account (`cloud-run-nat-poc`) and binds IAM roles. Run first with a privileged account (Owner/IAM Admin). Enables all required APIs.
- **`setup-infra.sh`** — Creates base infrastructure: hub + spoke VPCs, subnets, firewall rules, Artifact Registry, container images, VM, Cloud Run services/jobs. Idempotent. Run as the service account.
- **`setup-connectivity.sh`** — Creates HA VPN tunnels, BGP sessions, Hybrid NAT, Public NAT, and ILB with serverless NEG. Run after setup-infra.sh. Wait ~60s for BGP convergence.
- **`teardown.sh`** — Destroys all infrastructure including connectivity resources and the service account. Idempotent.
- **`test.sh`** — Tests both traffic flows: triggers Cloud Run Jobs (spoke→hub via NAT) and curls ILBs from VM (hub→spoke).

All scripts default `PROJECT_ID` to `sb-paul-g-workshop`. Region is `europe-north2`.

## Architecture

See `docs/architecture.md` for full details.

- **3 VPCs**: `hub`, `spoke-1`, `spoke-2` (custom subnet mode)
- **Hub**: Compute VM (`vm-hub`) on `10.0.0.0/28`, Public NAT for internet
- **Spokes**: Each has overlapping `240.0.0.0/8` (Cloud Run egress), routable `/28` (ILB), proxy-only `/26`, and PRIVATE_NAT `/24`
- **HA VPN**: 8 tunnels total (4 per spoke), BGP route exchange (non-overlapping only)
- **Hybrid NAT**: On each spoke, SNATs `240.x` → `172.16.x` for spoke→hub traffic
- **ILB**: HTTPS (self-signed cert, port 443) with serverless NEG on each spoke for hub→spoke traffic
- **Cloud Run**: 2 services (`cr-spoke-1`, `cr-spoke-2`) + 2 jobs (`job-spoke-1`, `job-spoke-2`)

## IAM Roles (bound by setup-iam.sh)

`roles/compute.networkAdmin`, `roles/compute.instanceAdmin.v1`, `roles/run.admin`, `roles/run.invoker`, `roles/vpcaccess.admin`, `roles/iam.serviceAccountUser`, `roles/iap.tunnelResourceAccessor`, `roles/artifactregistry.admin`, `roles/networkconnectivity.hubAdmin`

Cloud Run Service Agent also gets `roles/compute.networkUser` for Direct VPC egress.

## Issue Tracking

Uses Beads (`bd` CLI). See AGENTS.md.

## Session Close Protocol

Work is NOT complete until `git push` succeeds. See AGENTS.md for full checklist.

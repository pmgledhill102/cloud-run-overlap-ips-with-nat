# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

GCP proof-of-concept comparing two approaches for Cloud Run services with overlapping IP ranges across hub-spoke VPC architectures:

1. **Direct VPC Egress** (`direct-vpc-egress/`) — Cloud Run deploys into VPC with overlapping Class E IPs. Uses Hybrid NAT + HA VPN + ILB.
2. **VPC Connector** (`vpc-connector/`) — Cloud Run connects through VPC Access Connector VMs with unique IPs. Uses HA VPN + ILB (no Hybrid NAT).

Shared hub infrastructure (Artifact Registry, hub VPC, VM) is in `shared/`.

## Repository Structure

- **`setup-iam.sh`** — Creates service account (`cloud-run-nat-poc`) and binds IAM roles. Run first.
- **`shared/setup-hub.sh`** — Shared hub: Artifact Registry, container images, hub VPC, subnet, firewall, VM.
- **`shared/teardown-hub.sh`** — Hub teardown (guards against deleting while spokes exist).
- **`direct-vpc-egress/`** — Direct VPC Egress approach scripts and docs.
- **`vpc-connector/`** — VPC Connector approach scripts and docs.
- **`docs/comparison.md`** — Side-by-side comparison of approaches.

Each approach directory contains: `setup-infra.sh`, `setup-connectivity.sh`, `teardown.sh`, `test.sh`, and `docs/`.

All scripts default `PROJECT_ID` to `sb-paul-g-vpcsac`. Region is `europe-north2`.

## Architecture

See `docs/comparison.md` for the side-by-side overview.

### Direct VPC Egress (see `direct-vpc-egress/docs/architecture.md`)
- **3 VPCs**: `hub`, `spoke-1`, `spoke-2`
- **Spokes**: overlapping `240.0.0.0/8`, routable `/22`, proxy-only `/18`, PNAT `/24`
- **Hybrid NAT**: SNATs `240.x` → `172.16.x` for spoke→hub traffic
- **Cloud Run**: `cr-spoke-{1,2}`, `job-spoke-{1,2}` (Direct VPC Egress)

### VPC Connector (see `vpc-connector/docs/architecture.md`)
- **3 VPCs**: `hub`, `spoke-c1`, `spoke-c2`
- **Spokes**: connector `/28` (unique IPs), routable `/22`, proxy-only `/18`
- **No Hybrid NAT**: connector IPs are already routable
- **Cloud Run**: `cr-spoke-c{1,2}`, `job-spoke-c{1,2}` (VPC Connector)

### Shared
- **Hub**: VM (`vm-hub`) on `10.0.0.0/28`, Public NAT

## IAM Roles (bound by setup-iam.sh)

`roles/compute.networkAdmin`, `roles/compute.securityAdmin`, `roles/compute.instanceAdmin.v1`, `roles/run.admin`, `roles/run.invoker`, `roles/vpcaccess.admin`, `roles/iam.serviceAccountUser`, `roles/iap.tunnelResourceAccessor`, `roles/artifactregistry.admin`, `roles/networkconnectivity.hubAdmin`

Cloud Run Service Agent also gets `roles/compute.networkUser` for Direct VPC egress.

## Issue Tracking

Uses Beads (`bd` CLI). See AGENTS.md.

## Session Close Protocol

Work is NOT complete until `git push` succeeds. See AGENTS.md for full checklist.

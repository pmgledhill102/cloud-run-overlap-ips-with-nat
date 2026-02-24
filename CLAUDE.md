# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

GCP proof-of-concept demonstrating how Cloud Run services can use overlapping IP ranges across different VPCs, with the goal of having a single compute instance communicate with all of them. The base infrastructure is scripted; cross-VPC connectivity (Private NAT, NCC, PSC, VPC peering) is configured manually for experimentation.

## Scripts

- **`setup-iam.sh`** — Creates service account (`cloud-run-nat-poc`) and binds IAM roles. Run first with a privileged account (Owner/IAM Admin). Enables all required APIs.
- **`setup-infra.sh`** — Creates all infrastructure: VPCs, subnets, firewall rules, Artifact Registry, container image, 18 Cloud Run services, compute instance. Run as the service account (via impersonation). Idempotent. Scale by adjusting NUM_VPCS/NUM_SUBNETS_PER_VPC/NUM_SERVICES_PER_SUBNET at the top.
- **`teardown.sh`** — Destroys all infrastructure and the service account. Idempotent.
- **`load-test.sh`** — SSHs into the compute instance via IAP and sends requests to Cloud Run services. Usage: `./load-test.sh [vpc_number|all] [concurrency]`

All scripts read `PROJECT_ID` from `gcloud config get-value project`. Region is `europe-north2`.

## Architecture

- **2 VPC networks** (`vpc-1` through `vpc-2`), custom subnet mode (designed to scale to 5)
- **6 Class E subnets** (3 per VPC): `240.0.0.0/8` through `242.0.0.0/8` — these overlap across all VPCs intentionally
- **2 routable /28 subnets**: `10.0.0.0/28` and `10.1.0.0/28` — unique per VPC
- **1 compute subnet** in VPC-1: `10.2.0.0/28`
- **18 Cloud Run services** (3 per subnet × 3 subnets × 2 VPCs), named `cr-v{vpc}-s{subnet}-{nn}`
  - Go container (`container/`), sleeps 10s per request
  - Direct VPC egress into Class E subnets, private ingress only
  - maxInstances=20, minInstances=0, request-based billing
- **1 Compute Instance** (`nat-poc-vm`) in VPC-1, private IP only, SSH via IAP
- **1 Webserver Instance** (`nat-poc-webserver`) in VPC-1/compute-subnet, nginx on port 80, private IP only

## IAM Roles (bound by setup-iam.sh)

`roles/compute.networkAdmin`, `roles/compute.instanceAdmin.v1`, `roles/run.admin`, `roles/vpcaccess.admin`, `roles/iam.serviceAccountUser`, `roles/iap.tunnelResourceAccessor`, `roles/artifactregistry.admin`, `roles/networkconnectivity.hubAdmin`

Cloud Run Service Agent also gets `roles/compute.networkUser` for Direct VPC egress.

## Issue Tracking

Uses Beads (`bd` CLI). See AGENTS.md.

## Session Close Protocol

Work is NOT complete until `git push` succeeds. See AGENTS.md for full checklist.

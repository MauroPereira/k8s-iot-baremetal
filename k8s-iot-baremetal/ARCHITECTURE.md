# ARCHITECTURE.md - k8s-iot-baremetal

## Overview
This document describes the architectural decisions and design principles for the k8s-iot-baremetal cluster. This project provides a reliable, automated, and portable method for deploying a production-grade Kubernetes cluster on physical hardware without the overhead of heavy orchestration tools.

## High-Level Design
The architecture follows a standard **Kubernetes Control Plane / Worker** model, optimized for low-resource environments and bare metal stability.

### Deployment Model: "Ansible Push-Based Automation"
The deployment is managed by a modular Ansible playbook structured with roles.
- **Source of Truth**: `ansible/inventory.ini` and `ansible/group_vars/all.yml` serve as the inventory and configuration specification.
- **Agentless Execution**: Logic is executed on remote nodes via SSH using Ansible's native modules, ensuring idempotency and robustness.
- **Privilege Management**: Ansible's `become` (sudo) is used for administrative tasks, ensuring clear boundaries.

## Technology Stack & Rationale

| Component | Choice | Rationale |
|-----------|--------|-----------|
| **Orchestrator** | Kubernetes 1.32 (`packages.k8s.io`) | Vanilla upstream Kubernetes — portable, no vendor lock-in, cloud-migratable. |
| **Container Runtime** | containerd | High-performance, low-overhead industry-standard runtime (native K8s support). |
| **Networking (CNI)** | Cilium | eBPF-based CNI chosen for performance and observability in bare-metal environments. |
| **OS** | Ubuntu/Debian | Selected for broad hardware driver support and packaging stability. |

## Network Architecture
- **Control Plane Endpoint**: The API server is advertised on the physical IP of the designated control-plane node.
- **Pod Network (CIDR)**: `192.168.0.0/16`. This range is managed by Cilium and is isolated from the host physical network to prevent IP conflicts.
- **Communication Path**: Managed through `br_netfilter` and `overlay` modules, ensuring efficient packet routing between physical nodes.

## Security & Confidentiality Principles
1. **Configuration Masking**: Sensitive data (IPs, hostnames) is strictly managed through `.example` templates.
2. **Standardized Environment**: The project enforces a dedicated deployment user to simplify audit trails across nodes.
3. **Controlled Access**: SSH keys are the primary method of interaction, minimizing the exposure of static passwords in automation scripts.

## Design Decisions
1. **Version Locking (v1.32)**: The cluster is pinned to a specific stable version of Kubernetes components to ensure reproducibility and prevent breaking changes during automated updates.
2. **Systemd Cgroup Driver**: Native integration with the OS init system (systemd) for better resource accounting and stability.
3. **Automated Swap Management**: Swap is programmatically disabled to comply with Kubernetes memory management requirements, preventing performance degradation.
4. **Single Control Plane (No HA)**: This cluster intentionally runs a single control plane node. High availability (stacked etcd or external etcd) was ruled out to minimize resource consumption on bare metal hardware and reduce operational complexity for its intended use case. This is a known trade-off: if `k8s-node-00` becomes unavailable, the API server is unreachable until it recovers. Worker nodes and running workloads are unaffected by a temporary control plane outage.

## Known Hardware Constraint: x86-64-v2

### Problem
All three nodes run CPUs based on an older microarchitecture (pre-2012) that supports `cx16`, `popcnt`, and `lahf_lm` but **lacks `sse4_2`**, making them incompatible with the **x86-64-v2** microarchitecture level.

Starting with glibc ≥ 2.33, any binary compiled for x86-64-v2 raises a fatal runtime error on these CPUs:
```
Fatal glibc error: CPU does not support x86-64-v2
```

### Impact
Recent container images that ship UBI 9 or similar base images (glibc ≥ 2.34) crash on startup on these nodes. This constrains component version choices — newer versions of some ecosystem tools must be pinned to older releases that still use compatible base images.

### Compatibility Requirements
Any CPU with `sse4_2` in `/proc/cpuinfo` is fully compatible:
- Intel Core 2nd gen+ (Nehalem, 2008+)
- AMD FX / Ryzen (Bulldozer, 2012+)
- Any VM on a modern host with CPU type set to `host` or `x86-64-v2` (not `kvm64`)

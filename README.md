# Kubernetes Homelab

A GitOps-driven k3s cluster that runs the services I rely on every day while doubling as a platform engineering lab. The goal is to keep infrastructure repeatable, resilient, and easy to evolve while I experiment with new ideas.

## Objectives

- Maintain a reproducible home platform that mirrors modern production practices.
- Incrementally harden availability, storage, and security without sacrificing agility.
- Provide an opinionated reference for friends and future-me to follow when rebuilding.

## Architecture Snapshot

| Capability | Implementation | Notes |
|------------|----------------|-------|
| Kubernetes | k3s (2 nodes) | Lightweight control plane with room to grow to HA|
| GitOps | Argo CD app-of-apps | Every workload reconciled from Git; platform/test holds smoke tests |
| Networking | MetalLB + HAProxy Ingress | Split `haproxy-public`/`haproxy-restricted` classes, fronted by Cloudflare |
| Certificates | cert-manager with Let’s Encrypt | Automatic issuance and renewal for homelab domains |
| Storage | Longhorn | Replicated volumes, hourly snapshots, nightly NAS backups |
| Security | Namespaced secrets + network policies | Guardrails as defaults, expanding coverage app by app |
| Observability | On deck | LGTM stack design is scoped, implementation deferred until HA milestones land |

## Platform Layers

### Infrastructure (`infrastructure/`)
- k3s bootstrap configuration and install scripts for new nodes.
- System-level tuning captured next to the playbooks that apply it.

### Platform Services (`platform/`)
- `gitops/`: Argo CD core plus the root application that orchestrates everything else.
- `networking/`: MetalLB, HAProxy ingress, and cert-manager manifests.
- `security/`: Baseline network policies with room to expand RBAC and policy packs.
- `storage/`: Longhorn installation and storage class defaults.
- `management/`: Rancher deployment for clickops needs.
- `test/`: Smoke workloads used to validate new nodes, ingress, and certificates before promoting real apps.

### Applications (`apps/`)
- Media automation stacks (`arr`, `arr-lts`, `arr-lts2`), Plex, and supporting VPN workloads.
- Homelab UX (`homarr`, `portfolio`, router integrations) exposed through the public ingress.
- Productivity: Nextcloud with Collabora, Whiteboard, Vaultwarden, and Immich for photos.
- AI/Automation: Migrated from Ollama/OpenWebUI to a `llama.cpp` + LibreChat architecture with MongoDB, HPAs, PDBs, and dedicated PVCs for HA readiness.
- Qdrant vector store and additional services staged under `overlays/production` for cluster-wide policy control.

## High-Availability Progress

The cluster now runs on two nodes with Longhorn handling durable storage. Workloads being upgraded for failure tolerance include:

- `llama.cpp` and LibreChat split into stateful sets with separate scaling controls.
- Critical ingress, DNS, cert-manager, Vaultwarden, and the portfolio site run with replica spread and anti-affinity rules.
- Pod disruption budgets and topology constraints are rolling out to additional apps as I harden them.
- Backups and snapshots are verified nightly; restoring a service starts with Git and rehydrates from Longhorn.

## Repository Layout

```
k8s-homelab/
├── apps/               # Application base/overlay manifests
├── docs/               # Architecture notes, ADRs, and runbooks
├── infrastructure/     # Cluster bootstrap tooling (k3s install, node prep)
├── platform/           # Shared platform services, networking, storage, security
├── scripts/            # Helper scripts for maintenance
└── secrets/            # Git-ignored secret values referenced by manifests
```

Key architecture decisions live in `docs/decisions/` as ADRs for future reference.

## Operations

### Bootstrap a New Node
1. Clone the repository and review `infrastructure/k3s` for hardware-specific tweaks.
2. Run `scripts/install-k3s.sh` on the target node.
3. Apply the Argo CD bootstrap: `kubectl apply -k platform/gitops/argocd/`.
4. Deploy the root app: `kubectl apply -f platform/gitops/argocd/apps/root-app.yaml`.
5. Use the manifests in `platform/test/` to validate networking and certificates before syncing production apps.

### Day-2 Workflow
- Edit manifests, commit, and push; Argo CD reconciles within minutes.
- Track drift and sync states in the Argo CD UI or CLI.
- Scripts in `scripts/` help with recurring maintenance (node joins, certificate checks, etc.).

## Documentation

- `docs/architecture.md` captures the high-level platform blueprint.
- `docs/implementation-plan.md` outlines phased adoption and priorities.
- ADRs under `docs/decisions/` document the why behind major choices.
- Runbooks in `docs/runbooks/` (in progress) will house repeatable operational tasks.

## Roadmap

- Harden multi-node failover for remaining single-instance apps (media stack and productivity services).
- Finalize baseline network policies and service-to-service restrictions.
- Stand up the LGTM observability stack once HA groundwork is complete.
- Evaluate service mesh adoption after observability is live.

## License

This project is available under the MIT License.

---

Built for real-world use first, and as a playground for learning modern platform engineering along the way.

# Core Platform Two-Node HA Runbook (k3s + HAProxy + CoreDNS + Longhorn)

Purpose: achieve a stable two-node posture with zero flapping, controllers available on both nodes where applicable, able to survive single-node failure of worker-side components. Control plane remains single-writer until a third server is available.

Operating principles
- Safety first (read/observe/diff over mutate)
- No surprise scheduling (all apps stay on server-1 until explicitly migrated)
- Idempotent + reversible (every change has rollback)
- Evidence-driven (use kubectl and repo references)

Preconditions (verified)
- server-2 (worker-1) Ready,SchedulingDisabled with taint node.kubernetes.io/unschedulable:NoSchedule
- Only DaemonSets on worker-1 (Longhorn CSI, engine-image, metallb-speaker)
- Apps pinned to miniserver; qdrant lacked guardrails and will be constrained first

Contents
- 2.1 k3s Control Plane Posture
- 2.2 Ingress (HAProxy)
- 2.3 CoreDNS
- 2.4 Longhorn
- 2.5 Final validation
- Appendix: Risk Register & Anti-Flap

## 2.1 k3s Control Plane Posture

Detect current datastore (read-only)
- kubectl get nodes -o wide
- On server-1 host: sudo cat /etc/rancher/k3s/config.yaml (check datastore-endpoint)
- Inspect /var/lib/rancher/k3s/server/db/ for sqlite state.db vs etcd/
- Leader elections: kubectl -n kube-system get leases.coordination.k8s.io | egrep 'kube-scheduler|kube-controller'

Decision tree
- If single-server sqlite (expected): keep single-writer control plane on server-1; server-2 remains agent until third server is added
- To migrate to HA later (APPROVAL REQUIRED):
  - Preferred: add third server; convert to embedded etcd with 3 servers
  - Alternate: external HA datastore via HAProxy (advanced; not recommended for homelab)

Health checks
- kubectl get --raw=/readyz; kubectl get --raw=/healthz
- Validate controller/scheduler leases renew steadily

Rollback
- Re-cordon worker-1 and keep all workloads on miniserver; revert any datastore changes

## 2.2 Ingress (HAProxy)

Goal: two controller replicas (one per node) with anti-affinity and topology spread; or DaemonSet if 1-per-node is desired

Key settings (patch example; do not apply)
- replicas: 2
- podAntiAffinity required on kubernetes.io/hostname
- topologySpreadConstraints across kubernetes.io/hostname, maxSkew: 1, DoNotSchedule
- strict readiness/liveness probes to prevent endpoint churn

Drain/failover behavior
- Expect seamless endpoint updates; tune probe thresholds to avoid flap during drain

## 2.3 CoreDNS

Goal: two replicas spread across nodes

Recommendations
- replicas: 2
- preferred podAntiAffinity and topologySpreadConstraints
- resources: requests 50m/128Mi; limits 200m/256Mi
- health endpoints: readiness /ready (8181), liveness /health (8080)

Kubelet/resolver
- Ensure pods resolve via cluster DNS (e.g., 10.43.0.10). NodeLocal DNSCache optional later.

## 2.4 Longhorn (must not flap)

Target: exactly 2 replicas per volume (one per node). No exceptions.

Discovery (read-only)
- Volumes: kubectl -n longhorn-system get volumes.longhorn.io -o custom-columns=NAME:.metadata.name,REPLICAS:.spec.numberOfReplicas,ROBUST:.status.robustness
- Replicas: kubectl -n longhorn-system get replicas.longhorn.io -o custom-columns=NAME:.metadata.name,VOLUME:.spec.volumeName,NODE:.spec.nodeID,MODE:.status.mode
- Settings: kubectl -n longhorn-system get settings.longhorn.io | grep -E 'default-replica-count|replica-soft-anti-affinity|replica-auto-balance|replica-replenishment-wait-interval|concurrent-replica-rebuild-per-node-limit'

Global defaults (APPROVAL REQUIRED; use --dry-run=server first)
- default-replica-count = 2
- replica-soft-anti-affinity = false (enforce cross-node)
- replica-auto-balance = disabled (during migration)
- replica-replenishment-wait-interval = 600
- concurrent-replica-rebuild-per-node-limit = 1

Per-volume reconciliation (APPROVAL REQUIRED; stage one volume at a time)
- Patch spec.numberOfReplicas to 2
- Verify placement: one replica on miniserver, one on worker-1
- Avoid rebuild storms; pause if any volume starts rebuilding repeatedly

Verification
- All volumes healthy; numberOfReplicas = 2; replicas Longhorn CRDs show exactly one per node

## 2.5 Final validation

Simulated node loss (APPROVAL REQUIRED; maintenance window)
- Dry-run drain worker-1: kubectl drain worker-1 --ignore-daemonsets --delete-emptydir-data --force --dry-run=server
- Observe Events and Longhorn volume status; CoreDNS and HAProxy should remain available via surviving replica
- Success: no pod restart loops; no PVC detach/attach storms; Longhorn rebuild remains within safeguards; leader elections steady

Rollback
- Re-cordon worker-1; revert Longhorn settings; restore from snapshots if needed

## Appendix: Risk Register & Anti-Flap

Risks
- Longhorn rebuild storms; PVC re-attach loops
- Ingress endpoint oscillation; CoreDNS eviction loops
- Control-plane lease thrash

Prevent
- Lane guardrails; staged one-by-one volume changes
- Strict readiness gates; conservative probes; pause autoscalers
- Disable Longhorn auto-balance during migration

Detect
- kubectl get events -A -w; watch Longhorn robustness

Act
- Re-cordon worker-1; pin workloads to server-1; set rebuild concurrency to 0; argocd app rollback; restore snapshots

End of runbook.
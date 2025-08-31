# Per-App Migration Framework: Single-Node to Two-Node HA

Purpose: provide a repeatable, low-risk, idempotent, and reversible pattern to migrate each application from server-1-only to two-node HA while strictly preventing surprise scheduling on server-2 until explicitly approved.

Principles (non-negotiable)
- Safety first: prefer read/observe/diff over mutate
- No surprise scheduling: workloads stay on server-1 until the app explicitly “opts in”
- Idempotent + reversible: every step has a rollback
- Evidence-driven: prove safety with kubectl and Argo diffs, not assumptions
- Anti-flap: drain controls, conservative probes, staged Longhorn replica changes

See also
- Phase 0 Guardrails: [docs/runbooks/scheduling-guardrails-phase-0.md](./scheduling-guardrails-phase-0.md)
- Core Platform Two-Node Runbook: [docs/runbooks/core-platform-two-node.md](./core-platform-two-node.md)

Cluster lane model (assumed from Phase 0)
- server-1 (miniserver): label workload-lane=primary
- server-2 (worker-1): label workload-lane=secondary, taint workload-lane=secondary:NoSchedule
- Repo-wide default overlay (Phase 0) keeps apps on primary by default
- Apps “opt-in” to dual-lane by adding:
  - toleration for workload-lane=secondary:NoSchedule
  - nodeAffinity that allows both lanes (In [primary, secondary])
  - topology spread and anti-affinity for cross-node placement

APPROVAL REQUIRED markers indicate gated changes. Use --dry-run=server first when kubectl is involved.

--------------------------------------------------------------------------------

## 3.1 Pre-Migration Safety Gates (must pass before any migration)

Baseline health (server-1 steady)
- Zero CrashLoopBackOff, bounded restarts (e.g., <= 3 last 1h), probes green
- PDB exists with maxUnavailable: 0 for stateful single-replica or with safe budgets for multi-replica
- Resource requests set (avoid best-effort flapping under pressure)

Commands (read-only)
```bash
# App health
kubectl -n <ns> get pods -o wide
kubectl -n <ns> get events --sort-by=.lastTimestamp | tail -n 50
kubectl -n <ns> get deploy,sts,po -o jsonpath='{range .items[*]}{.kind}{"\t"}{.metadata.name}{"\t"}{.status.conditions[*].type}{"\t"}{.status.conditions[*].status}{"\n"}{end}'

# Restarts trend (last 1h)
kubectl -n <ns> get pods -o json | jq -r '.items[] | [.metadata.name, (.status.containerStatuses // [])[]?.restartCount] | @tsv'

# PDB presence
kubectl -n <ns> get pdb

# Requests/limits present
kubectl -n <ns> get deploy,sts -o json | jq -r '..|.resources? | select(.!=null)'
```

Data model classification (choose one)
- Stateless (no PVCs; idempotent)
- Stateful (sharedable, e.g., RWX content cache)
- Stateful (single-writer, e.g., RWO DB)
- Stateful (fragile DB; sensitive to restarts and clock skew)

Commands
```bash
# PVC/PV, AccessModes and StorageClass
kubectl -n <ns> get pvc
kubectl -n <ns> get pvc -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.accessModes}{"\t"}{.spec.storageClassName}{"\n"}{end}'

# Longhorn volume attachment and replicas (read-only)
kubectl -n longhorn-system get volumes.longhorn.io -o custom-columns=NAME:.metadata.name,REPLICAS:.spec.numberOfReplicas,ROBUST:.status.robustness
kubectl -n longhorn-system get replicas.longhorn.io -o custom-columns=NAME:.metadata.name,VOLUME:.spec.volumeName,NODE:.spec.nodeID,MODE:.status.mode
```

Storage coupling and Longhorn posture
- RWO (single-writer): only one pod may attach the volume at a time
- RWX (multi-writer): multiple pods may attach, assess application correctness
- Longhorn must maintain exactly 2 healthy replicas per volume (one per node)
- During any migration windows: disable replica auto-balance, keep low rebuild concurrency

Verify Longhorn safety (read-only)
```bash
kubectl -n longhorn-system get settings.longhorn.io | grep -E 'default-replica-count|replica-auto-balance|replica-soft-anti-affinity|concurrent-replica-rebuild-per-node-limit|replica-replenishment-wait-interval'

# Target steady-state expectations (documented; do not change without approval):
# - default-replica-count: 2
# - replica-soft-anti-affinity: false
# - replica-auto-balance: disabled
# - concurrent-replica-rebuild-per-node-limit: 1
# - replica-replenishment-wait-interval: 600
```

Guardrails sanity
```bash
# Ensure server-2 remains non-schedulable unless app opts in explicitly
kubectl get nodes -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints,UNSCHEDULABLE:.spec.unschedulable
kubectl get pods -A -o wide | grep worker-1 || true
```

--------------------------------------------------------------------------------

## 3.2 HA Strategies

Choose one per app. All examples are Kustomize patches layered over app base. Replace <ns>, <appLabel>, <deployName>.

Important: keep the app on server-1 until the moment you deliberately migrate. The key switch is tolerating the secondary lane taint and broadening nodeAffinity to include secondary.

### A) Active-Active (2 replicas; one per node)

Requirements
- App is stateless or uses a safe multi-writer datastore (or no PVC)
- Idempotent consumers; avoid sticky sessions (or use external session store)
- Longhorn volumes either not used, or RWX and semantics confirmed safe

Manifests pattern (patch)
```yaml
# 1) Prepare for dual-lane placement (APPROVAL REQUIRED)
#    Step A: set replicas=2; spread across nodes; still limited to primary only
apiVersion: apps/v1
kind: Deployment
metadata:
  name: <deployName>
spec:
  replicas: 2
  template:
    metadata:
      labels:
        app: <appLabel>
    spec:
      # default overlay from Phase 0 likely enforces primary only.
      # Keep it for now; this will schedule both replicas on server-1 (safe).
      topologySpreadConstraints:
      - maxSkew: 1
        topologyKey: kubernetes.io/hostname
        whenUnsatisfiable: DoNotSchedule
        labelSelector:
          matchLabels:
            app: <appLabel>
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
          - labelSelector:
              matchLabels:
                app: <appLabel>
            topologyKey: kubernetes.io/hostname
---
# 2) Opt-in to server-2 explicitly (APPROVAL REQUIRED, carefully timed)
#    - Add toleration for server-2 taint
#    - Allow nodeAffinity In [primary, secondary]
apiVersion: apps/v1
kind: Deployment
metadata:
  name: <deployName>
spec:
  template:
    spec:
      tolerations:
      - key: workload-lane
        operator: Equal
        value: secondary
        effect: NoSchedule
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - key: workload-lane
                operator: In
                values: ["primary","secondary"]
```

Ingress/session guidance
- Remove sticky sessions or externalize to Redis/JWT
- Validate that hash-based or header-based session affinity isn’t required

HPA considerations
- Temporarily pause HPA during cutover; re-enable after bake window

Rollout steps
1) Argo diff overlay patch (replicas=2, spread, anti-affinity, still primary-only)
2) Sync and verify both replicas on server-1; probes healthy
3) APPROVAL REQUIRED: add toleration + broaden nodeAffinity; sync
4) Verify one pod moves to worker-1 (observe scheduling), no flap in events

Rollback
- Revert toleration and narrow nodeAffinity to ["primary"], replicas back to previous

### B) Controlled Failover (primary on server-1, warm standby on server-2)

Requirements
- Single-writer datastores
- Predictable, gated failover with explicit promotion steps

Pattern options
- Option 1 (single Deployment): replicas=2 with preferredDuringScheduling toward primary; still requires toleration + broadened affinity to allow a standby replica to land on secondary. Ensure the standby does not violate single-writer semantics (usually not suitable for strict RWO DBs unless standby is read-only or blocked).
- Option 2 (dual Deployments): primary deployment (replicas=1) on primary; standby deployment (replicas=0) pre-provisioned on secondary. Scale standby to 1 only during failover.

Dual-Deployment example (safer for single-writer)
```yaml
# primary.yaml (stays on server-1)
apiVersion: apps/v1
kind: Deployment
metadata:
  name: <deployName>-primary
spec:
  replicas: 1
  template:
    metadata:
      labels:
        app: <appLabel>
        role: primary
    spec:
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - key: workload-lane
                operator: In
                values: ["primary"]
---
# standby.yaml (pre-provisioned on server-2, scaled to 0)
apiVersion: apps/v1
kind: Deployment
metadata:
  name: <deployName>-standby
spec:
  replicas: 0
  template:
    metadata:
      labels:
        app: <appLabel>
        role: standby
    spec:
      tolerations:
      - key: workload-lane
        operator: Equal
        value: secondary
        effect: NoSchedule
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - key: workload-lane
                operator: In
                values: ["secondary"]
```

Failover procedure (scripted)
- Scale primary to 0; scale standby to 1 (APPROVAL REQUIRED)
- Validate PVC attachment flip (RWO) and app health
- Rollback: reverse the scale operations

### C) Hybrid (active on server-1 + sidecar/queue/replication)

Requirements
- Fragile or integrated DBs; minimize write conflicts
- Mirror traffic or replicate data asynchronously

Patterns
- Add a replication sidecar or queue on secondary
- Keep primary pod(s) on server-1 only
- Longhorn replicas across nodes already in place
- Cutover runbook with quiesce window and data sync checkpoint

Manifest hints
```yaml
# Primary remains pinned on server-1, with a replication sidecar enabled.
apiVersion: apps/v1
kind: Deployment
metadata:
  name: <deployName>
spec:
  replicas: 1
  template:
    spec:
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - key: workload-lane
                operator: In
                values: ["primary"]
      # sidecar for replication/mirroring (example placeholder)
      containers:
      - name: app
        image: ghcr.io/example/app:latest
      - name: replicate
        image: ghcr.io/example/replicator:latest
        args: ["--dest", "secondary-node-addr-or-queue"]
```

Ingress/session
- Mirror traffic safely; ensure idempotency; verify that writes are not duplicated

Data plan
- Validate Longhorn replicas are healthy on both nodes before enabling mirroring

--------------------------------------------------------------------------------

## 3.3 The Actual Migration Checklist (one page)

Pre-checks
- Confirm app health on server-1 (no CrashLoopBackOff; probes green; bounded restarts)
- PDB exists and is appropriate for desired rollout
- Resource requests/limits present
- Longhorn: default-replica-count=2; one replica per node; auto-balance disabled; rebuild concurrency conservative

Opt-in gate (per-app)
- Label “migration/dual-lane: true” on the Argo app or Kustomize overlay branch/tag (convention)
- Keep Argo in “manual sync” for the app during the window

Apply manifests in stages
- Stage 1 (safe): replicas and topology spread; anti-affinity; still primary-only affinity
- Verify: events, endpoints, no flapping; still all on server-1
- Stage 2 (APPROVAL REQUIRED): add toleration for workload-lane=secondary and broaden nodeAffinity to ["primary","secondary"]
- Verify: one replica schedules on worker-1; zero restart loops; PVCs behave as expected

Optional controlled failover test
- Drain worker-1 (dry-run first) or scale deployments to simulate loss; observe stability
- Rollback immediately on any sign of flap

Bake time monitoring
- Watch events and pod restarts for N hours/days (define per app SLO)
- Keep autoscalers paused during bake window

Sign-off
- Record evidence (kubectl outputs, Argo diffs, Longhorn health snapshot)
- Switch app to normal GitOps auto-sync if desired

Rollback plan (precise)
- Remove toleration for secondary lane
- Narrow nodeAffinity back to ["primary"]
- Scale replicas back to 1 (or previous)
- If dual-deployment: scale standby=0; primary=1
- If PVC issues: re-attach to last healthy primary; restore from snapshot if needed

--------------------------------------------------------------------------------

## Evidence and Verification (copy/paste)

Read-only checks
```bash
# Pods and nodes
kubectl -n <ns> get deploy,sts,po -o wide
kubectl get nodes -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints,UNSCHEDULABLE:.spec.unschedulable

# Detect cross-node placement
kubectl -n <ns> get po -l app=<appLabel> -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.nodeName}{"\n"}{end}'

# Non-DS pods on worker-1 (should be expected only after opt-in)
kubectl get pods -A -o jsonpath='{range .items[?(@.spec.nodeName!="")]}'\
  '{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{.spec.nodeName}{"\t"}{.metadata.ownerReferences[0].kind}{"\n"}{end}' \
  | awk -F'\t' -v n=worker-1 '$3==n && $4!="DaemonSet"{print}'

# Longhorn volume/replica health
kubectl -n longhorn-system get volumes.longhorn.io -o custom-columns=NAME:.metadata.name,REPLICAS:.spec.numberOfReplicas,ROBUST:.status.robustness
kubectl -n longhorn-system get replicas.longhorn.io -o custom-columns=NAME:.metadata.name,VOLUME:.spec.volumeName,NODE:.spec.nodeID,MODE:.status.mode
```

Events to watch (flap detection)
```bash
kubectl get events -A --field-selector reason=FailedScheduling -w
kubectl -n <ns> get events --sort-by=.lastTimestamp -w
```

--------------------------------------------------------------------------------

## Appendix — Risk Register & Anti-Flap Playbook (per-app focus)

What can go wrong
- Longhorn replica rebuild storms; engine image mismatch
- PVC re-attach loops (RWO) on failover
- Ingress endpoint oscillation due to probes too aggressive
- CoreDNS eviction loops during spreads; leader election thrash

Prevent
- Keep lane taints/enforced affinity defaults; only opt-in per-app
- Stage Longhorn changes one volume at a time; disable auto-balance during migration
- Strict readiness gates and conservative probe thresholds during windows
- Pause autoscalers and HPAs during cutovers
- Use PDBs with maxUnavailable: 0 where appropriate to avoid sudden evictions

Detect early
- Tail FailedScheduling; inspect Longhorn robustness and replica placement
- Watch for repeated restarts or readiness probe flapping

Immediate actions if flapping starts
- Re-cordon server-2 (worker-1) and/or remove toleration from the app
- Scale deployments back to server-1 only; narrow nodeAffinity to ["primary"]
- Temporarily halt Longhorn rebuilds by lowering concurrency to 0 (APPROVAL REQUIRED)
- Revert last Argo sync (argocd app rollback)
- Restore from snapshots if data integrity is at risk

--------------------------------------------------------------------------------

## PR Planning Template (per app)

Commit 1 — Add “primary-only” staging patch
- files: overlays/<env>/<app>/primary-only/kustomization.yaml, patch-topology-and-anti-affinity.yaml
- message: chore(<app>): add primary-only staging overlay with spread and anti-affinity

Commit 2 — Opt-in patch for dual lane (gated)
- files: overlays/<env>/<app>/dual-lane/kustomization.yaml, patch-toleration-and-affinity.yaml
- message: feat(<app>): dual-lane opt-in (toleration + affinity In [primary,secondary])

Commit 3 — Docs & runbook artifacts
- files: docs/runbooks/migrations/<app>-<date>.md
- message: docs(<app>): migration evidence and rollback steps

All merges are code-only; no kubectl apply. Use ArgoCD for sync, with manual sync enabled during migration windows.

End of framework.
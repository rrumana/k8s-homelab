# Phase 0 — Scheduling Guardrails: Verification and Defense-in-Depth Plan

Purpose: verify cluster-wide guardrails that prevent any scheduling on server-2, document evidence, and propose a no-flap, idempotent PR plan. No changes are applied in this phase.

Operating principles
- Safety first: read/observe/diff over mutate
- No surprise scheduling: keep all workloads on server-1 until explicitly migrated
- Idempotent + reversible: every proposed change has rollback
- Evidence-driven: repo + kubectl outputs captured below

Scope
- server-1: miniserver (control-plane)
- server-2: worker-1 (added, cordoned/drained; treat as blank slate)

Status summary (verified)
- server-2 is cordoned and tainted unschedulable; only DaemonSets run there.
- Apps are pinned to server-1 via nodeName or nodeSelector. Exception: qdrant lacks placement guardrails today.
- No repo-wide default nodeAffinity overlay to prevent drift.

Evidence — Repository (read-only)
- nodeName pin: [k8s-homelab/apps/base/arr/deployment.yaml](k8s-homelab/apps/base/arr/deployment.yaml)
- nodeName pin: [k8s-homelab/apps/base/arr-lts/deployment.yaml](k8s-homelab/apps/base/arr-lts/deployment.yaml)
- nodeName pin: [k8s-homelab/apps/base/arr-lts2/deployment.yaml](k8s-homelab/apps/base/arr-lts2/deployment.yaml)
- nodeSelector miniserver: [k8s-homelab/apps/base/homarr/deployment.yaml](k8s-homelab/apps/base/homarr/deployment.yaml)
- nodeSelector miniserver: [k8s-homelab/apps/base/elasticsearch/deployment.yaml](k8s-homelab/apps/base/elasticsearch/deployment.yaml)
- Lacking guardrails (risk if server-2 made schedulable): [k8s-homelab/apps/base/qdrant/deployment.yaml](k8s-homelab/apps/base/qdrant/deployment.yaml)
- Argo apps point to base (no overlay defaults):
  - [k8s-homelab/platform/gitops/argocd/apps/arr-app.yaml](k8s-homelab/platform/gitops/argocd/apps/arr-app.yaml)
  - [k8s-homelab/platform/gitops/argocd/apps/arr-lts-app.yaml](k8s-homelab/platform/gitops/argocd/apps/arr-lts-app.yaml)
  - [k8s-homelab/platform/gitops/argocd/apps/qdrant-app.yaml](k8s-homelab/platform/gitops/argocd/apps/qdrant-app.yaml)
- Longhorn prereq contains a Longhorn setting string (does not taint nodes itself): [k8s-homelab/platform/storage/longhorn/prereqs/longhorn-force-single-node.yaml](k8s-homelab/platform/storage/longhorn/prereqs/longhorn-force-single-node.yaml)
- k3s API toleration tuning (not lane-specific): [k8s-homelab/infrastructure/k3s/config.yaml](k8s-homelab/infrastructure/k3s/config.yaml)

Evidence — Cluster (read-only)

Nodes and cordon/taint state
```bash
kubectl get nodes -o wide
kubectl get nodes -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints,UNSCHEDULABLE:.spec.unschedulable
kubectl describe node worker-1 | sed -n '1,120p'
```
Observed (summarized):
- worker-1: Ready,SchedulingDisabled; taint node.kubernetes.io/unschedulable:NoSchedule; Unschedulable=true.

Verify zero non-DaemonSet pods on server-2
```bash
# List any pods on worker-1
kubectl get pods -A -o wide | grep worker-1 || true

# Filter to non-DaemonSets on worker-1 (should print nothing)
kubectl get pods -A -o jsonpath='{range .items[?(@.spec.nodeName!="")]}'\
  '{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{.spec.nodeName}{"\t"}{.metadata.ownerReferences[0].kind}{"\n"}{end}' \
  | awk -F'\t' -v n=worker-1 '$3==n && $4!="DaemonSet"{print}'
```
Observed: only DaemonSets (Longhorn engine-image, longhorn-csi-plugin, metallb-speaker) present on worker-1.

Scan for tolerations/affinity that could place pods on server-2
```bash
kubectl get deploy,sts,ds -A -o jsonpath='{range .items[?(@.spec.template.spec.tolerations)]}{.metadata.namespace}{"\t"}{.kind}{"\t"}{.metadata.name}{"\t"}{.spec.template.spec.tolerations}{"\n"}{end}'
kubectl get deploy,sts -A -o jsonpath='{range .items[?(@.spec.template.spec.affinity)]}{.metadata.namespace}{"\t"}{.kind}{"\t"}{.metadata.name}{"\n"}{end}'
```
Observed: platform components have tolerations/affinity; no app-level tolerations matching a custom lane key.

Gaps
- No documented “lane” model (labels/taints) to guard against future drift.
- qdrant lacks placement constraints; would drift if server-2 became schedulable.
- Mixed pinning (nodeName vs nodeSelector) — safe now, but brittle for future HA.

Defense-in-Depth Guardrails (APPROVAL REQUIRED — do not apply yet)

1) Introduce lane labels (idempotent; reversible)
- server-1 (miniserver): workload-lane=primary
- server-2 (worker-1): workload-lane=secondary

Dry-run first:
```bash
kubectl label node miniserver workload-lane=primary --overwrite --dry-run=server -o yaml
kubectl label node worker-1  workload-lane=secondary --overwrite --dry-run=server -o yaml
```
Apply:
```bash
kubectl label node miniserver workload-lane=primary --overwrite
kubectl label node worker-1  workload-lane=secondary --overwrite
```
Rollback:
```bash
kubectl label node miniserver workload-lane-
kubectl label node worker-1  workload-lane-
```

2) Add lane taint on server-2 (requires explicit toleration; reversible)
- Key=workload-lane, Value=secondary, Effect=NoSchedule

Dry-run first:
```bash
kubectl taint node worker-1 workload-lane=secondary:NoSchedule --dry-run=server -o yaml
```
Apply:
```bash
kubectl taint node worker-1 workload-lane=secondary:NoSchedule
```
Rollback:
```bash
kubectl taint node worker-1 workload-lane:NoSchedule-
```

3) Repo-wide default nodeAffinity via overlay (no changes to pinned apps in Phase 0)
- Create an overlay that injects requiredDuringScheduling nodeAffinity to lane=primary.
- Start with qdrant (the only unguarded app).

Overlay files to add (PR only; no apply):
- [k8s-homelab/apps/overlays/primary-lane/qdrant/kustomization.yaml](k8s-homelab/apps/overlays/primary-lane/qdrant/kustomization.yaml)
- [k8s-homelab/apps/overlays/primary-lane/qdrant/patch-affinity.yaml](k8s-homelab/apps/overlays/primary-lane/qdrant/patch-affinity.yaml)

patch-affinity.yaml (example)
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: qdrant
spec:
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
```

4) Route Argo app to overlay (PR only; no apply)
- Edit [k8s-homelab/platform/gitops/argocd/apps/qdrant-app.yaml](k8s-homelab/platform/gitops/argocd/apps/qdrant-app.yaml) to use path apps/overlays/primary-lane/qdrant

Blast radius and stop conditions
- Minimal: labels/taint are safe while server-2 remains cordoned; overlay affects only qdrant and keeps it on server-1.
- Detection: tail FailedScheduling events; assert zero non-DS pods on worker-1.
- Stop: if any unexpected Pending, revert Argo app path or remove the lane taint; re-cordon worker-1.

Idempotency and rollback
- All kubectl label/taint operations are idempotent.
- Overlays are Git-only; revert via git revert / Argo rollback.

Verification after any approved apply
```bash
kubectl get nodes --show-labels
kubectl get nodes -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints,UNSCHEDULABLE:.spec.unschedulable
kubectl get pods -A -o wide | grep worker-1 || true
```

Guardrails PR plan (no apply)

Commit 1 — qdrant overlay
- Add: [k8s-homelab/apps/overlays/primary-lane/qdrant/kustomization.yaml](k8s-homelab/apps/overlays/primary-lane/qdrant/kustomization.yaml)
- Add: [k8s-homelab/apps/overlays/primary-lane/qdrant/patch-affinity.yaml](k8s-homelab/apps/overlays/primary-lane/qdrant/patch-affinity.yaml)
- Message: chore(qdrant): add primary-lane overlay to require workload-lane=primary

Commit 2 — Argo route to overlay
- Edit: [k8s-homelab/platform/gitops/argocd/apps/qdrant-app.yaml](k8s-homelab/platform/gitops/argocd/apps/qdrant-app.yaml) (spec.source.path → apps/overlays/primary-lane/qdrant)
- Message: feat(argo): route qdrant through primary-lane overlay

Commit 3 — docs
- Add: [k8s-homelab/docs/guardrails/lane-model.md](k8s-homelab/docs/guardrails/lane-model.md) with label/taint procedures, dry-run, and rollback
- Message: docs(guardrails): document lane labels/taints and rollback

Appendix — Commands (copy/paste friendly)
```bash
# Nodes
kubectl get nodes -o wide
kubectl get nodes -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints,UNSCHEDULABLE:.spec.unschedulable

# Validate server-2 non-DS
kubectl get pods -A -o wide | grep worker-1 || true
kubectl get pods -A -o jsonpath='{range .items[?(@.spec.nodeName!="")]}'\
  '{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{.spec.nodeName}{"\t"}{.metadata.ownerReferences[0].kind}{"\n"}{end}' \
  | awk -F'\t' -v n=worker-1 '$3==n && $4!="DaemonSet"{print}'

# Labels (APPROVAL REQUIRED)
kubectl label node miniserver workload-lane=primary --overwrite --dry-run=server -o yaml
kubectl label node worker-1  workload-lane=secondary --overwrite --dry-run=server -o yaml

# Taint (APPROVAL REQUIRED)
kubectl taint node worker-1 workload-lane=secondary:NoSchedule --dry-run=server -o yaml
```

End of Phase 0 runbook.
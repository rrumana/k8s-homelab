# Kubernetes Homelab Implementation Plan: From Zero to Production-Ready

## Overview and Philosophy

This implementation plan follows a "crawl, walk, run" philosophy where we start with the absolute minimum viable cluster and progressively add capabilities. Each phase is designed to be fully functional on its own, allowing you to pause and gain operational experience before adding complexity. The entire deployment remains declarative and version-controlled from day one, ensuring reproducibility and disaster recovery capabilities.

## Phase 0: Foundation and Prerequisites (Week 1)

### Setting Up Your Development Environment

Before touching Kubernetes, we establish a solid foundation for infrastructure as code. Create a dedicated Git repository with this initial structure:

```
k8s-homelab/
├── README.md                 # Documentation hub
├── .gitignore               # Exclude secrets and local files
├── docs/                    # Architecture decisions and runbooks
│   ├── architecture.md      # High-level design
│   ├── decisions/          # ADR format decisions
│   └── runbooks/           # Operational procedures
├── infrastructure/         # Base infrastructure
│   ├── k3s/               # Cluster bootstrap
│   └── ansible/           # Server configuration
├── platform/              # Platform services
│   ├── networking/        # Ingress, DNS, certs
│   ├── observability/     # Monitoring stack
│   ├── gitops/           # ArgoCD configuration
│   └── storage/          # Longhorn setup
├── apps/                 # Application deployments
│   ├── base/            # Kustomize bases
│   └── overlays/        # Environment-specific
└── scripts/             # Automation helpers
```

This structure separates concerns while maintaining clear relationships between components. The `infrastructure` directory contains everything needed to bootstrap a cluster, `platform` houses cluster-wide services, and `apps` contains your actual workloads.

### Initial Documentation Strategy

Create an Architecture Decision Record (ADR) for every significant choice. Start with `docs/decisions/001-k3s-selection.md`:

```markdown
# ADR-001: Selection of k3s as Kubernetes Distribution

## Status
Accepted

## Context
We need a Kubernetes distribution that balances production capabilities with resource efficiency for a homelab environment that will scale to multiple nodes.

## Decision
We will use k3s as our Kubernetes distribution.

## Consequences
- Positive: Low resource overhead, production-ready features, excellent ARM support
- Negative: Some differences from upstream Kubernetes, embedded components may limit flexibility
- Mitigation: Document any k3s-specific configurations for future migration if needed
```

This documentation pattern ensures future you (or team members) understand not just what was implemented, but why specific choices were made.

## Phase 1: Minimal Viable Cluster (Week 2)

### Installing k3s with Declarative Configuration

Rather than using the default k3s installation script directly, we'll create a declarative wrapper that ensures consistency. Create `infrastructure/k3s/install.yaml`:

```yaml
# k3s server configuration
apiVersion: v1
kind: Config
metadata:
  name: k3s-server
spec:
  # Disable components we'll replace with better alternatives
  disable:
    - traefik     # We'll use HAProxy/NGINX instead
    - servicelb   # We'll use MetalLB instead
  
  # Cluster configuration
  cluster-init: true
  cluster-cidr: "10.42.0.0/16"
  service-cidr: "10.43.0.0/16"
  
  # Performance optimizations
  kube-apiserver-arg:
    - "default-not-ready-toleration-seconds=10"
    - "default-unreachable-toleration-seconds=10"
  
  # Security hardening
  secrets-encryption: true
  
  # Data directory (ensure this is on SSD if possible)
  data-dir: "/var/lib/rancher/k3s"
```

Create an installation script at `scripts/bootstrap-cluster.sh`:

```bash
#!/bin/bash
set -euo pipefail

# This script bootstraps a k3s cluster with our specific configuration
# It's idempotent - safe to run multiple times

echo "🚀 Starting k3s cluster bootstrap..."

# Check prerequisites
command -v curl >/dev/null 2>&1 || { echo "curl is required but not installed. Aborting." >&2; exit 1; }

# Install k3s with our configuration
curl -sfL https://get.k3s.io | sh -s - server \
  --disable traefik \
  --disable servicelb \
  --cluster-init \
  --secrets-encryption

# Wait for k3s to be ready
echo "⏳ Waiting for k3s to be ready..."
while ! sudo k3s kubectl get nodes >/dev/null 2>&1; do
  sleep 5
done

# Copy kubeconfig for local access
mkdir -p ~/.kube
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown $USER:$USER ~/.kube/config
sed -i 's/127.0.0.1/YOUR_SERVER_IP/g' ~/.kube/config

echo "✅ k3s cluster bootstrapped successfully!"
echo "🔧 Run 'kubectl get nodes' to verify cluster status"
```

### Initial Cluster Validation

After installation, create a simple validation deployment to ensure everything works. Create `platform/test/hello-world.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hello-world
  namespace: default
spec:
  replicas: 1
  selector:
    matchLabels:
      app: hello-world
  template:
    metadata:
      labels:
        app: hello-world
    spec:
      containers:
      - name: hello
        image: nginxdemos/hello:latest
        ports:
        - containerPort: 80
        resources:
          requests:
            memory: "64Mi"
            cpu: "50m"
          limits:
            memory: "128Mi"
            cpu: "100m"
```

This simple deployment validates that your cluster can schedule pods, pull images, and manage resources correctly.

## Phase 2: Networking Foundation (Week 3)

### Implementing MetalLB for Load Balancing

MetalLB enables LoadBalancer services in bare-metal environments. Create `platform/networking/metallb/values.yaml`:

```yaml
# MetalLB configuration for homelab
# This allocates a range of IPs from your home network
configInline:
  address-pools:
  - name: default
    protocol: layer2
    addresses:
    - 192.168.1.200-192.168.1.210  # Adjust to your network

# Resource constraints for homelab
controller:
  resources:
    limits:
      cpu: 100m
      memory: 100Mi
speaker:
  resources:
    limits:
      cpu: 100m
      memory: 100Mi
```

### Installing HAProxy Ingress Controller

Based on our performance analysis, HAProxy provides the best balance of performance and features. Create `platform/networking/haproxy-ingress/values.yaml`:

```yaml
# HAProxy Ingress Controller configuration
controller:
  # Enable high-performance mode
  config:
    ssl-redirect: "true"
    use-forwarded-headers: "true"
    
  # Resource allocation for homelab
  resources:
    requests:
      cpu: 100m
      memory: 128Mi
    limits:
      cpu: 500m
      memory: 512Mi
      
  # Service configuration
  service:
    type: LoadBalancer
    annotations:
      metallb.universe.tf/address-pool: default
```

### Automated Certificate Management

Cert-manager automates TLS certificate provisioning. Create `platform/networking/cert-manager/cluster-issuer.yaml`:

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: your-email@example.com  # Update this
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
    - http01:
        ingress:
          class: haproxy
```

## Phase 3: GitOps Implementation (Week 4)

### ArgoCD Bootstrap Process

GitOps ensures all changes go through version control. Create a sophisticated ArgoCD setup at `platform/gitops/argocd/values.yaml`:

```yaml
# ArgoCD configuration for homelab
configs:
  params:
    # Increase sync frequency for faster feedback
    application.instanceLabelKey: argocd.argoproj.io/instance
    controller.status.processors: 10
    controller.operation.processors: 5
    
  repositories:
    k8s-homelab:
      url: https://github.com/YOUR_USERNAME/k8s-homelab
      name: k8s-homelab
      type: git

# Resource allocation
controller:
  resources:
    requests:
      cpu: 250m
      memory: 512Mi
    limits:
      cpu: 500m
      memory: 1Gi

server:
  resources:
    requests:
      cpu: 50m
      memory: 128Mi
    limits:
      cpu: 200m
      memory: 256Mi

# Enable metrics for monitoring
metrics:
  enabled: true
  serviceMonitor:
    enabled: true
```

### App of Apps Pattern

Implement the "app of apps" pattern for managing ArgoCD applications. Create `platform/gitops/argocd/apps/root-app.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root-app
  namespace: argocd
  finalizers:
  - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://github.com/YOUR_USERNAME/k8s-homelab
    targetRevision: HEAD
    path: platform/gitops/argocd/apps
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
    - CreateNamespace=true
```

## Phase 4: Observability Stack (Week 5-6)

### LGTM Stack Deployment Strategy

The observability stack requires careful resource planning. Start with a minimal configuration and scale based on actual usage. Create `platform/observability/kube-prometheus-stack/values.yaml`:

```yaml
# Prometheus configuration
prometheus:
  prometheusSpec:
    # Retention and storage
    retention: 30d
    storageSpec:
      volumeClaimTemplate:
        spec:
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 50Gi
    
    # Resource allocation
    resources:
      requests:
        cpu: 500m
        memory: 2Gi
      limits:
        cpu: 2000m
        memory: 4Gi
    
    # Scrape configurations
    additionalScrapeConfigs:
    - job_name: 'k3s'
      kubernetes_sd_configs:
      - role: node
      relabel_configs:
      - source_labels: [__address__]
        regex: '(.*):10250'
        replacement: '${1}:10249'
        target_label: __address__

# Grafana configuration
grafana:
  persistence:
    enabled: true
    size: 10Gi
  
  # Pre-configured dashboards
  dashboardProviders:
    dashboardproviders.yaml:
      apiVersion: 1
      providers:
      - name: 'default'
        orgId: 1
        folder: ''
        type: file
        disableDeletion: false
        updateIntervalSeconds: 10
        options:
          path: /var/lib/grafana/dashboards/default
  
  # Resource allocation
  resources:
    requests:
      cpu: 100m
      memory: 128Mi
    limits:
      cpu: 200m
      memory: 256Mi
```

### Loki for Log Aggregation

Configure Loki with efficient storage and retention. Create `platform/observability/loki/values.yaml`:

```yaml
# Loki configuration for homelab
loki:
  auth_enabled: false
  
  config:
    # Storage configuration
    storage_config:
      boltdb_shipper:
        active_index_directory: /loki/boltdb-shipper-active
        cache_location: /loki/boltdb-shipper-cache
        shared_store: filesystem
      filesystem:
        directory: /loki/chunks
    
    # Retention policy
    table_manager:
      retention_deletes_enabled: true
      retention_period: 168h  # 7 days
    
    # Performance limits
    limits_config:
      enforce_metric_name: false
      reject_old_samples: true
      reject_old_samples_max_age: 168h
      max_cache_freshness_per_query: 10m

# Single binary mode for simplicity
singleBinary:
  replicas: 1
  persistence:
    enabled: true
    size: 20Gi
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: 500m
      memory: 512Mi
```

## Phase 5: Storage Evolution (Week 7)

### Longhorn Distributed Storage

Longhorn provides distributed storage with minimal complexity. Create `platform/storage/longhorn/values.yaml`:

```yaml
# Longhorn configuration
defaultSettings:
  # Replicas for data protection
  defaultReplicaCount: 2
  
  # Backup configuration (optional S3 endpoint)
  backupTarget: ""
  backupTargetCredentialSecret: ""
  
  # Performance settings
  guaranteedEngineManagerCPU: 0.1
  guaranteedReplicaManagerCPU: 0.1

# UI configuration
ui:
  resources:
    requests:
      cpu: 50m
      memory: 64Mi
    limits:
      cpu: 100m
      memory: 128Mi

# Storage class configuration
persistence:
  defaultClass: true
  defaultClassReplicaCount: 2
  reclaimPolicy: Delete
```

### Migration Strategy from HostPath

Create a migration runbook at `docs/runbooks/hostpath-to-longhorn-migration.md`:

```markdown
# HostPath to Longhorn Migration Guide

This guide walks through migrating existing hostPath volumes to Longhorn distributed storage.

## Prerequisites
- Longhorn installed and healthy
- Application downtime window identified
- Backup of existing data completed

## Migration Steps

1. **Create new PVC with Longhorn**
   ```yaml
   apiVersion: v1
   kind: PersistentVolumeClaim
   metadata:
     name: app-data-longhorn
   spec:
     accessModes:
       - ReadWriteOnce
     storageClassName: longhorn
     resources:
       requests:
         storage: 10Gi
   ```

2. **Create migration job**
   ```yaml
   apiVersion: batch/v1
   kind: Job
   metadata:
     name: data-migration
   spec:
     template:
       spec:
         containers:
         - name: migrate
           image: busybox
           command: ["sh", "-c", "cp -r /source/* /dest/"]
           volumeMounts:
           - name: source
             mountPath: /source
           - name: dest
             mountPath: /dest
         volumes:
         - name: source
           hostPath:
             path: /original/path
         - name: dest
           persistentVolumeClaim:
             claimName: app-data-longhorn
         restartPolicy: Never
   ```

3. **Update application to use new PVC**
4. **Verify data integrity**
5. **Clean up old hostPath data**
```

## Phase 6: Application Deployment (Week 8)

### Structuring Applications with Kustomize

Create a robust application structure that supports multiple environments. For your Immich deployment, create `apps/base/immich/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: immich

resources:
  - namespace.yaml
  - postgres/
  - redis/
  - server/
  - machine-learning/

# Common labels for all resources
commonLabels:
  app.kubernetes.io/name: immich
  app.kubernetes.io/instance: homelab

# Configure resource requests/limits
patches:
  - target:
      kind: Deployment
      name: ".*"
    patch: |-
      - op: add
        path: /spec/template/spec/containers/0/resources
        value:
          requests:
            memory: "256Mi"
            cpu: "100m"
          limits:
            memory: "2Gi"
            cpu: "2000m"
```

### Environment-Specific Overlays

Create environment-specific configurations at `apps/overlays/production/immich/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

bases:
  - ../../../base/immich

# Production-specific patches
patches:
  - target:
      kind: Deployment
      name: immich-server
    patch: |-
      - op: replace
        path: /spec/replicas
        value: 2
      - op: add
        path: /spec/template/spec/affinity
        value:
          podAntiAffinity:
            preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              podAffinityTerm:
                labelSelector:
                  matchExpressions:
                  - key: app
                    operator: In
                    values:
                    - immich-server
                topologyKey: kubernetes.io/hostname

# Production secrets management
secretGenerator:
  - name: immich-secrets
    env: secrets.env
```

## Phase 7: Security Implementation (Week 9)

### Progressive Security Hardening

Start with network policies that default to deny. Create `platform/security/network-policies/default-deny.yaml`:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: default
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
---
# Allow DNS for all pods
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns
  namespace: default
spec:
  podSelector: {}
  policyTypes:
  - Egress
  egress:
  - to:
    - namespaceSelector:
        matchLabels:
          name: kube-system
    ports:
    - protocol: UDP
      port: 53
```

### Container Scanning Pipeline

Integrate Trivy for automated scanning. Create `.github/workflows/security-scan.yaml`:

```yaml
name: Security Scan

on:
  push:
    branches: [ main ]
  pull_request:
    branches: [ main ]

jobs:
  scan:
    runs-on: ubuntu-latest
    steps:
    - uses: actions/checkout@v3
    
    - name: Run Trivy vulnerability scanner
      uses: aquasecurity/trivy-action@master
      with:
        scan-type: 'config'
        scan-ref: '.'
        format: 'sarif'
        output: 'trivy-results.sarif'
    
    - name: Upload Trivy scan results
      uses: github/codeql-action/upload-sarif@v2
      with:
        sarif_file: 'trivy-results.sarif'
```

## Timeline and Milestones

### Month 1: Foundation
- **Week 1**: Repository setup, documentation structure, initial planning
- **Week 2**: k3s installation, basic cluster validation
- **Week 3**: Networking layer (MetalLB, HAProxy, cert-manager)
- **Week 4**: GitOps implementation with ArgoCD

### Month 2: Platform Services
- **Week 5-6**: Observability stack (Prometheus, Grafana, Loki)
- **Week 7**: Storage evolution to Longhorn
- **Week 8**: Application deployment patterns

### Month 3: Production Readiness
- **Week 9**: Security implementation
- **Week 10**: Backup and disaster recovery
- **Week 11**: Performance tuning and optimization
- **Week 12**: Documentation completion and knowledge transfer

## Managing Complexity Through Documentation

### Runbook Structure

Every operational procedure gets a runbook. Example structure for `docs/runbooks/cluster-upgrade.md`:

```markdown
# Cluster Upgrade Runbook

## Pre-requisites
- [ ] Backup completed
- [ ] Maintenance window scheduled
- [ ] Rollback plan documented

## Upgrade Steps
1. Verify current version: `kubectl version`
2. Check deprecation guide for breaking changes
3. Update infrastructure code
4. Apply changes through GitOps
5. Monitor cluster health

## Validation
- [ ] All nodes healthy
- [ ] All pods running
- [ ] Ingress functional
- [ ] Monitoring operational

## Rollback Procedure
[Detailed steps if upgrade fails]
```

### Decision Tracking

Maintain a decision log for future reference. Each significant choice becomes an ADR with clear context, alternatives considered, and rationale for the decision.

## Maintaining Declarative Infrastructure

### GitOps Principles

Everything goes through Git. No manual kubectl commands in production. Changes follow this flow:

1. Create feature branch
2. Modify declarative configuration
3. Test in development overlay
4. Create pull request
5. Review and approve
6. ArgoCD automatically syncs changes

### Secret Management

Never commit secrets to Git. Use sealed-secrets or external-secrets operator:

```yaml
apiVersion: bitnami.com/v1alpha1
kind: SealedSecret
metadata:
  name: app-secrets
  namespace: default
spec:
  encryptedData:
    api-key: AgBvA7JqoXQ... # Encrypted value
```

## Disaster Recovery Preparedness

### Backup Strategy

Implement the 3-2-1 backup rule:
- 3 copies of important data
- 2 different storage types
- 1 offsite backup

Create `platform/backup/velero/schedule.yaml`:

```yaml
apiVersion: velero.io/v1
kind: Schedule
metadata:
  name: daily-backup
  namespace: velero
spec:
  schedule: "0 2 * * *"  # 2 AM daily
  template:
    includedNamespaces:
    - "*"
    excludedNamespaces:
    - kube-system
    - kube-public
    ttl: 720h  # 30 days retention
```

### Recovery Testing

Monthly disaster recovery drills ensure your backups work:

1. Restore to test cluster
2. Verify application functionality
3. Document any issues
4. Update runbooks accordingly

## Continuous Improvement

### Monitoring Your Progress

Create dashboards that track:
- Resource utilization trends
- Application performance metrics
- Cost optimization opportunities
- Security compliance status

### Regular Architecture Reviews

Monthly reviews assess:
- What's working well
- Pain points encountered
- Opportunities for optimization
- New tools or patterns to evaluate

### Knowledge Sharing

Document learnings in blog posts or team presentations. Teaching others solidifies your own understanding while contributing to the community.

## Conclusion

This implementation plan provides a structured path from empty server to production-ready Kubernetes cluster. By following these phases, you'll build not just a cluster, but a deep understanding of each component and how they interact. Remember that Kubernetes is a journey, not a destination - embrace continuous learning and improvement as core principles of your homelab operation.

The key to success lies in maintaining discipline around declarative configuration, comprehensive documentation, and incremental complexity growth. Your future self will thank you for the investment in proper structure and documentation from day one.
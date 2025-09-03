# 🏠 Kubernetes Homelab: A Production-Ready Learning Journey

> *A modern, GitOps-driven Kubernetes homelab built for learning, experimenting, and having fun with enterprise-grade technologies in a home environment.*

This project represents a comprehensive Kubernetes homelab implementation that follows 2025 best practices, combining the thrill of learning cutting-edge technologies with the satisfaction of running a rock-solid home infrastructure. It's designed as both a learning platform and a production-ready deployment that can scale from a single node to a multi-node cluster.

## 🎯 Why This Project Exists

I built this homelab because **I find this stuff super fun!** There's something pretty magical about that moment when it just works. And I really use it! I am pushing for 100% data freedom and this platform helps quite a bit.

This isn't just infrastructure – it's a playground for exploring the latest in cloud-native technologies while running real applications that I use daily.

## 🏗️ Architecture Overview

This homelab follows a **"crawl, walk, run"** philosophy, starting with minimal viable infrastructure and progressively adding capabilities. Every component is declarative, version-controlled, and follows GitOps principles from day one.

### Technology Stack

| Component | Technology | Why This Choice |
|-----------|------------|-----------------|
| **Kubernetes Distribution** | k3s | Production-grade with <100MB footprint, perfect for homelab |
| **Load Balancer** | MetalLB | Enables LoadBalancer services on bare metal |
| **Ingress Controller** | HAProxy | Honestly just to learn it |
| **GitOps** | ArgoCD | Industry standard with "app of apps" pattern |
| **Certificate Management** | cert-manager + Let's Encrypt | Automatic TLS certificates for all services |
| **Container Runtime** | containerd | k3s default, lightweight and reliable |

### Network Architecture

```
Internet → Cloudflare → HAProxy Ingress → Services
                      ↑
                 MetalLB LoadBalancer
```

**Ingress Classes:**
- `haproxy-public`: External-facing services with full TLS
- `haproxy-restricted`: Internal services with network restrictions

## 🆕 Recent Cluster Changes

- Added a second node to form a two-node cluster (control plane remains single-writer/non-HA).
- Longhorn deployed and all application storage migrated to Longhorn; volumes are replicated across both nodes.
- Critical services run with 2 replicas and anti-affinity to survive loss of the control-plane node:
  - HAProxy Ingress, CoreDNS, cert-manager, Vaultwarden, and the Portfolio site.
- Replica spreading enforced via podAntiAffinity/topologySpreadConstraints.
- Data protection: Longhorn snapshots run hourly; backups are taken nightly to NAS.

## 📁 Project Structure

```
k8s-homelab/
├── 📚 docs/                    # Architecture decisions and documentation
│   ├── decisions/              # Architecture Decision Records (ADRs)
│   └── templates/              # Templates for ingress patterns and more
├── 🏗️ infrastructure/          # Cluster bootstrap and base config
│   └──k3s/                   # k3s installation and configuration
├── 🔧 platform/               # Platform services (the foundation)
│   ├── gitops/                # ArgoCD configuration and apps
│   ├── networking/            # MetalLB, HAProxy, cert-manager
│   ├── observability/         # Monitoring stack (planned)
│   ├── security/              # Network policies and RBAC (more coming)
│   └── storage/               # Longhorn distributed storage
├── 🚀 apps/                   # Application deployments
│   ├── base/                  # Kustomize base configurations
│   ├── overlays/              # Environment-specific overrides
│   ├── host/                  # Hosted publicly exposed applications
│   └── other/                 # External service integrations
├── 🔐 secrets/                # Kubernetes secrets (gitignored values)
└── 📜 scripts/                # Installation and management scripts
```

## 🚀 Applications & Services

### 🎬 Media & Entertainment Stack
- **qBittorrent**: BitTorrent client with VPN integration (Linux ISOs and AI models)
- **Plex**: Media streaming server
- **Gluetun**: VPN container for secure torrenting

### 🏠 Homelab Management
- **Homarr**: Dashboard for all homelab services
- **Unifi Controller**: Network equipment management
- **Router Integration**: Direct integration with home router

### 🤖 AI & Development
- **Ollama**: Local LLM inference with WebUI
- **Qdrant**: Vector database for AI applications
- **Portfolio Site**: Personal website hosting

### 🔒 Security & Productivity  
- **Vaultwarden**: Self-hosted Bitwarden compatible password manager
- **Immich**: Google Photos alternative with AI-powered features
- **Nextcloud**: Google Drive alternative with Collabora Online (CODE) and Whiteboard enabled

### 📊 Platform Services
- **ArgoCD**: GitOps continuous deployment
- **Rancher**: Cluster management
- **cert-manager**: Automatic TLS certificate management
- **MetalLB**: Load balancer for bare metal
- **HAProxy**: High-performance ingress controller
- **Longhorn**: Distributed block storage; all PVCs migrated; replicated across both nodes

## 🛡️ High Availability & Resilience

- Cluster posture: 2 nodes (single-writer control plane). Critical workloads are multi-replica with strict anti-affinity to tolerate a node failure.
- Critical services with replicas on both nodes:
  - HAProxy Ingress Controller
  - CoreDNS
  - cert-manager
  - Vaultwarden
  - Portfolio website
- Storage:
  - Longhorn provides replicated storage across both nodes
  - Snapshots: hourly
  - Backups: nightly to NAS


## 🎓 Learning Objectives

This homelab is designed to teach modern DevOps and platform engineering concepts:

### 🐣 Concepts Explored:
- Kubernetes fundamentals and resource management
- YAML manifest creation and management
- Basic networking concepts (Services, Ingress)
- Container orchestration principles
- GitOps workflows and CI/CD pipelines
- Kustomize for configuration management
- TLS/SSL certificate automation
- Resource allocation and optimization
- Storage management with persistent volumes
- Multi-environment deployment strategies
- Advanced networking with multiple ingress classes
- Infrastructure as Code best practices

## 🛠️ Getting Started

### Prerequisites
- Linux server/VM with 16GB+ RAM and 4+ CPU cores (you could use less but I don't reccomend it)
- Docker installed
- Domain name with DNS access
- Basic familiarity with Kubernetes concepts

### Quick Start

1. **Clone and Setup**
   ```bash
   git clone https://github.com/rrumana/k8s-homelab.git
   cd k8s-homelab
   ```

2. **Install k3s**
   ```bash
   ./scripts/install-k3s.sh
   ```

3. **Bootstrap ArgoCD** 
   ```bash
   kubectl apply -k platform/gitops/argocd/
   ```

4. **Deploy Platform Services**
   ```bash
   kubectl apply -f platform/gitops/argocd/apps/root-app.yaml
   ```

## 🔧 Configuration Management

### GitOps Workflow
1. **Make Changes**: Modify YAML files in Git
2. **Commit & Push**: Changes automatically trigger ArgoCD sync
3. **Monitor**: Watch deployments in ArgoCD UI
4. **Verify**: Check application status and logs

### Secrets Management
- Kubernetes native secrets with proper namespacing
- Sensitive values stored in separate `secrets/` directory
- Environment-specific configurations using Kustomize overlays

### Environment Strategy
- **Base**: Common configurations shared across environments
- **Overlays**: Environment-specific patches and customizations
- **Multiple Arr Stacks**: Different configurations for testing (arr, arr-lts, arr-lts2)

## 🌐 Access Points

All services are accessible via clean subdomains:

| Service | URL | Purpose |
|---------|-----|---------|
| ArgoCD | `argocd.rcrumana.xyz` | GitOps dashboard |
| Homarr | `homarr.rcrumana.xyz` | Homelab dashboard |
| Sonarr | `sonarr.rcrumana.xyz` | TV show management |
| Radarr | `radarr.rcrumana.xyz` | Movie management |
| Plex | `plex.rcrumana.xyz` | Media streaming |
| Immich | `immich.rcrumana.xyz` | Photo management |
| And many more... | | |

## 📋 Architecture Decisions

Key architectural decisions are documented as ADRs (Architecture Decision Records):

- **[ADR-001](docs/decisions/001-k3s-selection.md)**: Why k3s over other Kubernetes distributions
- **[ADR-002](docs/decisions/002-metallb-selection.md)**: MetalLB vs k3s ServiceLB
- **[ADR-003](docs/decisions/003-haproxy-selection.md)**: HAProxy vs NGINX ingress controller  
- **[ADR-004](docs/decisions/004-ingress-class-division.md)**: Separate public/restricted ingress classes

## 🔍 Monitoring & Observability

LGTM stack (Loki, Grafana, Tempo, Mimir) is planned next and will be added shortly.

## 🚀 What Makes This Special

### Modern 2025 Best Practices
- **GitOps-First**: Everything is declarative and version-controlled
- **Security-Focused**: Network policies, RBAC, and proper secret management
- **Production-Ready**: Resource limits, health checks, and monitoring
- **Scalable**: Designed to grow from single-node to multi-node clusters

### Real-World Applications
- **Daily Use**: These aren't toy apps – they run my actual media server, password manager, and development tools
- **Enterprise Patterns**: Same technologies and patterns used in production environments
- **Learning Playground**: Safe environment to experiment with breaking changes

## 🎯 Future Roadmap

### Phase 1: Core Platform ✅
- [x] k3s cluster foundation
- [x] GitOps with ArgoCD
- [x] Networking (MetalLB + HAProxy)
- [x] TLS automation

### Phase 2: Application Ecosystem ✅  
- [x] Media management stack
- [x] Homelab dashboard
- [x] AI/ML services
- [x] Productivity applications

### Phase 3: Advanced Platform 🚧
- [ ] Full observability stack (LGTM)
- [ ] Service mesh (Linkerd)
- [x] Advanced storage (Longhorn)
- [x] Backup and disaster recovery (hourly snapshots, nightly NAS backups)

### Phase 4: Enterprise Features 📋
- [ ] Multi-cluster management
- [ ] Advanced security policies
- [ ] Performance optimization
- [ ] Cost optimization tooling

## 🤝 Contributing

This is primarily a personal learning project, but I welcome:
- **Issues**: Report bugs or suggest improvements
- **Discussions**: Share your own homelab experiences
- **Documentation**: Help improve guides and explanations
- **Ideas**: Suggest new applications or platform improvements

## 📚 Learning Resources

### Recommended Reading
- [Kubernetes Documentation](https://kubernetes.io/docs/)
- [ArgoCD Documentation](https://argo-cd.readthedocs.io/)
- [k3s Documentation](https://docs.k3s.io/)

### Related Projects
- [awesome-kubernetes](https://github.com/ramitsurana/awesome-kubernetes)
- [homelab-gitops](https://github.com/k8s-at-home/charts)
- [cluster-template](https://github.com/onedr0p/cluster-template)

## 📄 License

This project is open source and available under the MIT License. Use it, learn from it, and make it your own!

---

*Built with ❤️ for learning, experimentation, and the pure joy of running enterprise-grade infrastructure at home.*

**Happy Homelabbing! 🏠✨**
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
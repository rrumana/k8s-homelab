# ADR-002: Selection of MetalLB as primary load balancer

## Status
Accepted

## Context
We need a versatile and feature-rich load balancer for cluster that balances efficiency with the feature set needed for scaling.

## Decision
we will use MetalLB as our primary load balancer.

## Consequences
- Positive: More versatile and feature rich for bare metal setups.
- Negative: Heavier and more complex than k3s default ServiceLB.
- Mitigation: Disable ServiceLB and document differences between two balancers.
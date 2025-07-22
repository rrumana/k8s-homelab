# ADR-003: Selection of HAProxy as reverse proxy

## Status
Accepted

## Context
We need an ingress controller that is highly performant, configurable, and scalable.

## Decision
Since this cluster is a learning tool as much as it is a stable deployment, we will choose HAProxy.

## Consequences
- Positive: Highly performant, scalable, and configurable.
- Negative: Different from current NGINX setup, somewhat complicated setup and migration.
- Mitigation: Document any HAProxy differences to NGINX, longer migration timescale.
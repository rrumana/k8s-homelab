# ADR-005: Using Longhorn as block storage system
## Status
Accepted

## Context
We need to centralize storage and prepare for eventual multi-node setup.

## Decision
We will use longhorn for its ease of use and distributed nature, replacing default storage classes.

## Consequences
- Positive: Easy setup & migration, convenient ui, works great with k3s
- Negative: Not as comprehensive as Ceph, will likely have to upgrade later.
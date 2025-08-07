# ADR-004: Dividing HAProxy ingress classes
## Status
Accepted

## Context
We need to visually distinguish between services that require extra security and those which do not.

## Decision
Public and restricted ingress classes will be made separate as a form of documentation, security will be implemented on a per-service level.

## Consequences
- Positive: Intent Documentation, Future Flexibility, and Simplified Cert-Manager Configuration.
- Negative: Complexity Without Direct Benefit, Potential for Confusion.
- Mitigation: Write templates for different HAProxy ingress implementations.
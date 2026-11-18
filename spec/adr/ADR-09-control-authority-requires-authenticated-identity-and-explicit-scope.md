# ADR-09: Control Authority Requires Authenticated Identity and Explicit Scope

**Status:** superseded by [ADR-14](ADR-14-a-controller-controls-what-it-opened.md)
**Date:** 2026-11-02

## Context

Programs drive applets, create pane layouts, and request effects such as clipboard access or starting another
program. These effects have different scopes. Permission to update a presentation does not imply permission to read
the clipboard or run an arbitrary executable.

Repeated approval dialogs interrupt legitimate work and encourage habitual approval. Remembering trust avoids those
interruptions, but a saved approval must identify the controller it applies to. A process name, path, or interpreter
executable does not establish which controller code is running. Layout restoration also creates new processes and
pane identities, so it cannot restore a former connection's authority.

## Decision

Every programmatic control effect requires an authenticated requester and an explicit, revocable grant covering the
operation and its current targets. Identity alone grants no permission.

- A grant is limited to its authorized window, targets, and powers. Pane control, clipboard reads, clipboard writes,
  runtime capabilities, and host-side program execution are separate powers. Ownership or one granted power never
  silently grants another.
- A remembered approval is a policy for a verified controller version or identity. Each run establishes a fresh
  authenticated binding to the actual controller and its current target scope. Claimed names, paths, digests, and
  the identity of a shared interpreter are insufficient proof of script identity.
- An unchanged or narrower permission request can reuse its approval. Additional powers, broader scopes, or a change
  in permission meaning cannot increase an existing approval without the user's consent. A signing identity proves
  continuity, not permission for every future effect.
- Authorization is checked at the effect boundary. Queued work cannot retain authority after its grant is revoked
  or its live requester binding is invalidated. Persisting policy does not persist a connection or live ownership.
- Remembered permission does not override a user's disconnected pane or confer ownership of restored panes.
  Permission and execution intent remain separate. Restored state never starts a controller automatically, per ADR-03.
- The claimed requester scope cannot be narrower than the transport can establish. A terminal-session request that
  cannot identify its originating program cannot use a particular script's persistent approval.

This is application authorization. It does not provide OS isolation from malicious processes of the same user or
guarantee the behavior of approved code.

## Rationale

Separating identity from permission makes remembered trust useful without turning it into blanket authority.
Separating policy from the live binding lets approval survive legitimate restarts while rejecting stale ownership
and impersonation. Checking the current scope at the effect boundary prevents queued requests from escaping
revocation.

These rules apply across control transports, applets, persistence, and process hosting. They do not depend on a
particular package format, signature representation, or pane-tree implementation.

## Consequences

- Controllers can repeat approved work without repeated dialogs. A change in authority requires renewed consent.
- Every control entry point uses the same permission boundaries, including applet commands and host-side effects.
- Controller verification and current run binding are necessary before reusing saved approval. A new transport
  cannot treat a controller's self-description as authentication.
- Revocation prevents new authorized effects. It cannot undo external effects an approved program already performed.
- A permission-format or interpretation change cannot silently broaden stored approvals. Unsupported meanings
  authorize nothing.

## Alternatives Considered

- **Ask for every effect.** This avoids reusable approval but interrupts ordinary repeated work. It does not make
  habitual approval a sound authorization boundary.
- **Trust a name, path, or interpreter across runs.** Another program or script can share those attributes without
  being the approved controller.
- **Treat trusted identity or pane ownership as blanket permission.** This silently extends approval to unrelated
  powers and targets.
- **Restore live grants with layout state.** The restored processes and panes are new instances. Stored state alone
  cannot establish their authority.

## References

- [UTERM-004](../proposals/UTERM-004-control-and-trust.md): originating proposal; controller trust, permission scopes,
  verified run binding, ownership, and saved layouts
- [ADR-02](ADR-02-pane-tree-nodes-have-stable-ids.md): stable node identity
- [ADR-03](ADR-03-restored-state-never-runs-a-program.md): inert restored state

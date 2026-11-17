# ADR-13: Outside Wires Stay Compatible Across Versions

**Status:** accepted
**Date:** 2026-11-16

## Context

uniterm speaks two kinds of wire. ScriptWire runs between the app and the `uniterm` helper, and both ship in one bundle.
A relaunch heals a version mismatch there. Each side therefore refuses any version but its own.

The exec wire runs between the app and an exec driver. A driver is a program in any language. It is deployed apart from
uniterm and updated on its own schedule. The exec wire took the same exact-match rule. Its versions 2, 3, and 4 were
each a plain bump. Each bump refused every driver on another version, including drivers that used none of the new
messages.

UTERM-028 adds commands to the exec wire. A change to a wire between separately deployed units must tolerate either
side's older version.

## Decision

A wire between uniterm and a separately deployed program keeps working when either side is older.

- Each version of such a wire keeps one fixed meaning. A change in meaning is a new version, never a reinterpretation of
  an old one.
- Each side tolerates the other side's older version. A program on an older version runs with what that version
  offers. A newer program on an older uniterm does the same.
- uniterm stops accepting an old version only under a proposal that names the direction that fails and the programs it
  breaks.
- A wire whose two sides always ship together, such as ScriptWire, may refuse every version but its own, per UTERM-024
  "Version skew".

## Rationale

A separately deployed program cannot update in step with uniterm. Rollouts stall, users skip updates, and a third-party
driver may never update. Refusing such a program on every bump breaks it for changes it never uses.

Repeated breaks also make uniterm a poor target for driver authors.

A fixed meaning per version keeps an old program from reading a new meaning into a message it already knows. UTERM-004
"Exec wire format" gives the same reason for versioning the exec wire at all: unversioned text leaves old commands
liable to new meanings.

## Consequences

- The app carries every version of an outside wire that it still accepts, with each version's behavior.
- An outside wire's handshake lets the two sides agree on a version. Later versions extend the handshake without
  breaking programs on earlier ones. UTERM-028 "Version skew" holds the exec wire's form of it.
- Dropping a version is a breaking change. It needs its own proposal and its own risk entry.

## Alternatives Considered

- **Exact-match refusal, as before.** It is simple. It refuses before any effect. It also breaks every deployed program
  on each bump, including programs that never use the new messages.
- **Optional features inside one version.** It avoids new version numbers. A version's meaning then grows over time,
  which is what versioning exists to prevent.
- **Accepting several versions with no agreement step.** A side that speaks first must commit to one version. Either an
  old or a new program on the other side then refuses it.

## References

- [UTERM-028](../proposals/UTERM-028-exec-driver-commands.md): "Version skew", the originating decision
- [UTERM-004](../proposals/UTERM-004-control-and-trust.md): "Exec wire format", whose exact-match rule this departs from
  for the exec wire
- [UTERM-024](../proposals/UTERM-024-controller-input-channel.md): "Version skew", ScriptWire's exact-match rule
- [ADR-06](ADR-06-layout-file-versioning-and-schema-ownership.md): versioning for stored layout files

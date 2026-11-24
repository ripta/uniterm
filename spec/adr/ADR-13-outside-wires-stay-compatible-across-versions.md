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

## Principles

A wire between uniterm and a separately deployed program keeps working when either side is older. A separately deployed
program cannot update in step with uniterm. Rollouts stall, users skip updates, and a third-party driver may never
update.

- **P1**: Each version of such a wire keeps one fixed meaning. A change in meaning is a new version, never a
  reinterpretation of an old one. A version's meaning covers what is inside its replies. An added reply field, like a
  change to what a field means, is a new version. A connection on an older version gets the older form. A fixed meaning
  keeps an old program from reading a new meaning into a message it already knows. It also lets a program tell what it
  is offered from the version alone. UTERM-004 "Exec wire format" gives the same reason for versioning the exec wire at
  all: unversioned text leaves old commands liable to new meanings.
- **P2**: Each side tolerates the other side's older version. A program on an older version runs with what that version
  offers. A newer program on an older uniterm does the same. Refusing such a program on every bump breaks it for changes
  it never uses. Repeated breaks also make uniterm a poor target for driver authors.
- **P3**: uniterm stops accepting an old version only under a proposal that names the direction that fails and the
  programs it breaks. Otherwise a program breaks with no one having weighed it.
- **P4**: The rule governs the wire's protocol version. A version of a contract the wire carries, such as an applet's
  command schema version, keeps its own rule, since that contract has its own version.
- **P5**: The rule holds from the version named for each wire. For the exec wire that is 4. For ScriptWire's
  messages other than the bundled command's own, it is 14. Earlier versions were refused before the rule applied, so it
  does not reach them.
- **P6**: Messages made for the app and its own bundled command may refuse every version but their own, whichever
  program sends them, since the two ship together and a relaunch heals a mismatch. Every other ScriptWire message is an
  outside wire. UTERM-024 "Version skew" holds the command's form of the rule.

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

## Amendments

- 2026-11-23: P1 covers what is inside a reply, added fields included. A changed field can break a program
  with no new version, and an added one makes two apps on one version offer different things. P5
  names a starting version for each wire, since ScriptWire was not counted when this ADR was adopted. P6 covers only
  the messages of the app's own bundled command, since a program that ships outside the bundle cannot relaunch to heal a
  mismatch.
  Removed: "The rule holds from the versions an outside wire accepted when this ADR was adopted. The exec wire's
  versions 2 and 3 were already refused then." Removed: "A wire whose two sides always ship together, such as
  ScriptWire, may refuse every version but its own, per UTERM-024 "Version skew"." The Decision and Rationale sections
  were rewritten as principles with no other change in meaning.

## References

- [UTERM-028](../proposals/UTERM-028-exec-driver-commands.md): "Version skew", the originating decision
- [UTERM-004](../proposals/UTERM-004-control-and-trust.md): "Exec wire format", whose exact-match rule this departs from
  for the exec wire
- [UTERM-024](../proposals/UTERM-024-controller-input-channel.md): "Version skew", ScriptWire's exact-match rule
- [ADR-06](ADR-06-layout-file-versioning-and-schema-ownership.md): versioning for stored layout files

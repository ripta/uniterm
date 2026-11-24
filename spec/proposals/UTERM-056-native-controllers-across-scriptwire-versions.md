# UTERM-056: Native Controllers Across ScriptWire Versions

**Status:** draft
**Created:** 2026-11-23
**Updated:** 2026-11-23

## Dependencies

- UTERM-004, for controller packages and their `native` entry kind
- UTERM-021, for the adoption of every connection a native entry opens after `uniterm controller run` execs it

## Impacts

- UTERM-054 — "Version skew" and the risk "A native controller stops connecting after the capture calls ship". Both
  accept the refusal until this proposal settles what a native controller's wire is.
- UTERM-019 — "Result encoding", whose skew line says app and helper ship in one bundle and a mismatch is refused at
  the hello. That holds for the helper and not for a native controller.

## ADR Deviations

None yet. Each candidate under "What a native controller's wire is" names the ADR-13 change it would need.

## Summary

Decide what happens to a native controller when the app's ScriptWire version changes. Today any change refuses every
native controller built against another version, and the error tells the user to relaunch, which cannot help.

## Motivation

A controller package whose entry is `native` runs its own signed executable. `uniterm controller run` execs it, and the
executable opens its own ScriptWire connections to the app. `ScriptControllers.adoptNativeRun` adopts them. The
executable carries its own copy of the wire, built when the controller was built.

ScriptWire's hello accepts only the app's exact version. `ScriptProtocol.validateHello` refuses any other version, in
both directions. So an app update that changes ScriptWire refuses every native controller built against the earlier
version. A native controller built against a newer version is refused by an older app.

The user then reads `ScriptProtocol.mismatchText`: "The uniterm command and the app come from different versions.
Relaunch uniterm." A relaunch cannot fix it, since the controller's executable is not part of the app bundle.

ADR-13 lets ScriptWire refuse every version but its own because its two sides always ship together. A native controller
is a ScriptWire side that ships outside the bundle, so that premise does not hold for it. ADR-13 also says a wire
between uniterm and a separately deployed program keeps working when either side is older.

Several queued proposals change ScriptWire, UTERM-019 and UTERM-054 among them. Each one breaks every deployed native
controller as it lands.

Filed from bug
[20261122-native-controller-refused-after-scriptwire-change](../bugs/20261122-native-controller-refused-after-scriptwire-change.md).
The trace was confirmed against the tree on 2026-11-23 at ScriptWire version 14. No native controller was built and
run.

## Design Decisions (Settled)

None.

## Design Decisions (Open)

### What a native controller's wire is

Whether a native controller's ScriptWire connection is an outside wire, a bundled one, or not offered at all. The rest
of the design follows from this answer.

Candidates:

- An outside wire under ADR-13. The app offers ScriptWire versions at the hello and keeps each version's meaning, as
  UTERM-028 does for the exec wire. ADR-13's ScriptWire line gains a carve-out: the helper keeps exact match, and a
  native controller does not. The app carries every version it still accepts, with each version's behavior. That cost
  grows with each ScriptWire change.
- A bundled wire, with exact match kept. ADR-13 is amended to say a native controller must be rebuilt for each
  ScriptWire change. The mismatch text changes so a native controller's user is told to update the controller, not to
  relaunch. Leaves undone: every ScriptWire change still breaks deployed native controllers.
- No native entries. Controllers run only through uniterm's own helper, and the `native` entry kind is withdrawn from
  UTERM-004's descriptor. ADR-13 needs no change. Leaves undone: signed packages with a native entry stop loading, so
  this needs a migration story for them and is a one-way door.
- No rule. Today's behavior stays: exact match, and a mismatch text that tells the user to relaunch. This is the bug
  itself, and it conflicts with ADR-13's rule for separately deployed programs.

### How the hello agrees on a version

Applies only if a native controller's wire is an outside wire. Candidates include a version list in the app's hello
that the controller picks from, as UTERM-028 adds for the exec wire, and an app that accepts any version in a fixed
window. Open: how many earlier versions the app keeps, and what proposal retires one, per ADR-13.

### What the user sees on a refused native controller

Every candidate above still refuses some native controller: one too old for the app's window, or one built for a newer
app. Open: what the error names, such as the controller's package, and what it tells the user to do. The helper's own
mismatch keeps the relaunch text.

## Risks

- **Every queued ScriptWire change breaks deployed native controllers until this settles** — likelihood: high, impact:
  medium. UTERM-019 and UTERM-054 change ScriptWire. Mitigation: UTERM-054 accepts this in its Risks, and this
  proposal is where the fix lands. Native controllers are third-party code, so the count deployed is unknown.
- **Withdrawing native entries strands signed packages** — likelihood: medium, impact: high, if that candidate wins.
  Mitigation: it is listed as a one-way door, and choosing it needs a migration story first.

## Milestones

To be written once the open questions settle.

## Decision Log

- 2026-11-23: Filed as a draft from bug `20261122-native-controller-refused-after-scriptwire-change`. The user asked
  for a proposal at its triage. The bug's three fix options became candidates under "What a native controller's wire
  is". "No rule" was added as the plain behavior. The version agreement and the refusal text became follow-up questions.

## References

- [ADR-13](../adr/ADR-13-outside-wires-stay-compatible-across-versions.md): outside wires stay compatible across
  versions, and ScriptWire's exact-match line
- [UTERM-028](UTERM-028-exec-driver-commands.md): "Version skew", the exec wire's version offer
- [UTERM-024](UTERM-024-controller-input-channel.md): "Version skew", ScriptWire's exact-match rule
- Bug [20261122-native-controller-refused-after-scriptwire-change](../bugs/20261122-native-controller-refused-after-scriptwire-change.md)

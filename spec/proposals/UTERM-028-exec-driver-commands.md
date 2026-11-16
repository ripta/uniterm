# UTERM-028: Exec Driver Commands

**Status:** draft
**Created:** 2026-11-15
**Updated:** 2026-11-15

## Dependencies

- UTERM-024, for controller commands, keys, and events
- UTERM-004, for exec drivers, their launch approval, and the exec wire
- UTERM-013, for key ownership

## Impacts

- UTERM-004 — "Exec wire format": the exec protocol gains a version. UTERM-004 is implemented, so this supersedes its
  version rule in part if both versions are accepted.

## Summary

Lets an exec driver declare commands and receive their invocations, as UTERM-024 lets a Janet controller. It is not
required by the presentation controller, which is a Janet controller.

## Motivation

An exec driver is a controller in any language. A driver that wants named user actions, such as Rerun or Step, has the
same gap a Janet controller has. Today a driver hears only its own pane's applet events.

## Design Decisions (Settled)

### The same commands and limits

Decision: a driver's commands follow UTERM-024's rules: the same keys, the same opt-in rule for panes,
the same key ownership, and the same cleanup when the driver ends.

## Design Decisions (Open)

### How a driver gets the power

Drivers have no `declare-permissions`. Their launch approval binds the argv, directory, and environment. How a driver
obtains the command power, or is refused it, and what label the palette shows for it, since a driver has no verified
title.

### Which panes are the driver's

UTERM-024 makes commands live in the controller's groups. A driver's own pane is its anchor, not a group member, so a
driver that requests no layout has no live panes. Whether the anchor pane counts, and whether its commands survive a
revocation that leaves the driver its own channel.

### Version skew

Exec drivers are separately deployed programs, and the app accepts only its exact protocol version today. A plain bump
refuses every deployed driver, including ones that never declare a command. Options:

- **The app accepts both versions.** Only drivers on the new version may declare commands and receive invocations.
  Deployed drivers keep working. This is the complete option.
- **A plain bump.** Every deployed driver is refused until it updates.

### How invocations reach the driver

Drivers already read stdin for events and out-of-order replies, so neither option adds a read loop.

- **Pushed.** The app sends an invocation message, as it sends applet events. A stalled driver fills the 4 MiB queue and
  is ended, which UTERM-019 "Page events" rejected for slow handlers.
- **The same cursor read as Janet.** A stalled driver loses only the oldest events, with a count, under UTERM-024's
  limits.

## Risks

- **A new exec protocol version is a published contract that third-party drivers depend on** — likelihood: high,
  impact: high. Mitigation: settle "Version skew" so deployed drivers keep working.

## Milestones

### M1: Driver commands

**Status:** NOT STARTED

- An exec driver declares commands and receives their invocations
- A deployed driver on the previous protocol version behaves as before, if "Version skew" settles on accepting both

## Decision Log

- 2026-11-15: Split from UTERM-024, which narrowed to what the presentation controller requires.

## References

- ADR-04: uniterm owns key bindings
- ADR-07: failure isolation
- ADR-09: control authority requires authenticated identity and explicit scope
- ADR-11: deferred applet replies never hide effects

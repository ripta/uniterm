# UTERM-028: Exec Driver Commands

**Status:** draft
**Created:** 2026-11-15
**Updated:** 2026-11-15

## Dependencies

- UTERM-024, for controller commands, shortcuts, and events
- UTERM-004, for exec drivers and the exec wire

## Impacts

- UTERM-004 — "Exec wire format": the exec protocol version goes up.

## Summary

Lets an exec driver declare commands and receive their invocations, as UTERM-024 lets a Janet controller. It is not
required by the presentation controller, which is a Janet controller.

## Motivation

An exec driver is a controller in any language. A driver that wants named user actions, such as Rerun or Step, has
the same gap a Janet controller has. Today a driver hears only its own pane's applet events.

## Design Decisions (Settled)

### The same commands and limits

Decision: a driver's commands follow UTERM-024's rules: live only in the driver's panes, the same key ownership, and
the same cleanup when the driver ends or is revoked.

### Version skew

Decision: the exec protocol refuses an unknown version at the hello, as it does today. An older driver and a newer app,
or the reverse, fail before any effect.

## Design Decisions (Open)

### How invocations reach the driver

- **Pushed.** The app sends an invocation message on the driver's stdin pipe, as it sends applet events. A driver needs
  no read loop.
- **The same read as Janet.** One model for both transports, at the cost of a read loop in every driver.

## Risks

- **A new exec protocol version is a published contract** — likelihood: high, impact: medium. Mitigation: the hello
  refuses an unknown version before any effect.

## Milestones

### M1: Driver commands

**Status:** NOT STARTED

- An exec driver declares commands and receives their invocations
- A driver that speaks an older exec protocol is refused at the hello, before any effect

## Decision Log

- 2026-11-15: Split from UTERM-024, which narrowed to what the presentation controller requires.

## References

- ADR-09: control authority requires authenticated identity and explicit scope

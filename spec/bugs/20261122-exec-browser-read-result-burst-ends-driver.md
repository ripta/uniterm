# A driver that sends its browser reads in a burst is ended

**Status:** open
**Found:** 2026-11-22, during the UTERM-055 review
**Validation:** confirmed against UTERM-019's text and the exec transport; UTERM-019 M3 is not built yet

## Observed

UTERM-019 gives exec drivers a browser read-result at protocol version 4. It reaches a driver as a member command, and
each reply carries one chunk of a result as a base64 string. The app keeps at most 4 MiB of unsent output per driver,
and an overflow ends the driver.

A driver reading a large PDF or script result can send every read at once, then read its stdin. Its replies fill the
queue, and the app ends the driver. That also ends its run, its powers, and its handles. Pushed applet events lower how
many replies fit.

UTERM-055 holds a capture's reads until the queue has room. Its review chose not to cover UTERM-019's reads from there.
Doing so would give version 4 drivers a new `busy` refusal, against ADR-13.

## Cause

- The outbound cap and the overflow that ends the driver: `ExecTransport.send` in
  `Packages/UnitermKit/Sources/ExecDriver/ExecTransport.swift`, and `maxRetainedBytes` in `ExecProtocol.swift`
- UTERM-019, "Large results" and "Result encoding", which chunk results under a handle and name no bound on reads in
  flight
- UTERM-019 sets no chunk size for the exec wire beyond "a chunk's encoding fits one reply"

## Repro

By trace, once UTERM-019 M3 is built. A driver owns a browser member, runs a script that returns a result of several
MiB, and sends every read-result for its handle before it reads its stdin. Expected: it receives every chunk. As
designed: the queue overflows and the app ends the driver.

## Fix

This needs a design call in UTERM-019, before its M3 ships:

- Hold a read-result reply until the queue has room, as UTERM-055 "How the app bounds reads in flight" settles for
  captures. M3 can reuse that hold, and adopting it from the first release changes no published meaning.
- Refuse a read with `busy` when the queue is near full. Every driver then needs retry logic.
- State a chunk size and a count of reads in flight in the documentation, and enforce nothing.

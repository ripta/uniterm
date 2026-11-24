# A driver that sends its browser reads in a burst is ended

**Status:** fixed 2026-11-23
**Fixed:** 2026-11-23, in the spec. UTERM-019 settles the bound before M3 builds the code.
**Estimate:** medium; one non-trivial design decision, settled by the user on 2026-11-23.
**Found:** 2026-11-22, during the UTERM-055 review

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

## Fix note

Triaged on 2026-11-23. The trace still held. `ExecTransport.send` ends a driver whose unsent output passes
`maxRetainedBytes`, which is 4 MiB. UTERM-019 named no bound on reads in flight. UTERM-055 narrowed its hold to capture
reads. Neither UTERM-019 M3 nor UTERM-055 M1 is built, so nothing could be run.

The user chose the hold. UTERM-019 gained "How the app bounds browser reads in flight", a Risks entry, and M3 checks.
An exec read-result reply waits until the outbound queue has room. Exec chunks hold at most 512 KiB. A read past the
held count is refused with `busy`. A driver that sends every read before reading its stdin gets every chunk.

M3 builds the hold, since the queue puts UTERM-055 M1 after M3. UTERM-055's "How the app bounds reads in flight", its
risk, its Dependencies, its M1 checks, and its queue row now say capture reads reuse that hold, with one count for both
result pools.

No regression test exists yet, because the code is not built. The M3 checks pin the fix: a driver that sends every
read-result at the per-result cap before reading its stdin receives every chunk and is not ended.

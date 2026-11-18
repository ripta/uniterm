# A driver's stderr line split across two reads shows as two status lines

**Status:** open
**Validation:** confirmed in a unit test, and in a failed full `make test-package` run. Not checked in the running app.
**Found:** 2026-11-17, while tracing the `ExecDriverChannelTests` flake in `spec/flaky-tests.md`

## Observed

A full `make test-package` run on 2026-11-17 failed
`ExecDriverChannelTests.testAnOversizeClipboardWriteIsRefusedAloneAndOneAtTheBoundArrives`. The status history held
`["got reply", "got error", "bad-argument", "error message: …", "got reply"]`. The fixture driver wrote one line,
`got error bad-argument`. The history shows it as two lines, `got error` and `bad-argument`.

## Cause

- The fixture prints the line with a list: `print STDERR "got $type", " $code", "\n"`
  (`Packages/UnitermKit/Tests/ExecTestSupport/Fixtures/driver.pl:72`). STDERR is unbuffered, so Perl can write each
  piece with its own `write(2)`.
- The transport's stderr reader hands each `read(2)` to `StderrIngress.offer` as it arrives
  (`Packages/UnitermKit/Sources/ExecDriver/ExecTransport.swift:297-312`).
- `offer` splits each chunk on newlines and keeps every piece as a whole line, including an unterminated tail
  (`Packages/UnitermKit/Sources/StatusKit/StderrIngress.swift`). It holds nothing back for the next chunk.
- When the reader wakes between the two writes, the two halves land in separate chunks and become two lines. That only
  happens when the reader is fast relative to the driver, which is why the test passes alone and fails under load.

A unit test that offers `"got error"` and then `" bad-argument\n"` gets two lines back where one is expected.

Any driver that writes a line in pieces hits this, not just the fixture. Unbuffered stderr is common, and a pipe can
also split a long write.

## Repro

```swift
let ingress = StderrIngress()
ingress.offer("got error")
ingress.offer(" bad-argument\n")
ingress.drain().lines.map(\.text)
```

- Expected: `["got error bad-argument"]`.
- Actual: `["got error", "bad-argument"]`.

## Fix

The ingress should keep an unterminated tail and join it with the next chunk. The design call is what happens to a tail
whose newline never comes:

- Hold the tail until its newline, until it passes `maximumLineBytes`, or until the stream ends, then emit it. This is
  the simplest fix. A driver that prints a partial line, such as a progress note, and then goes quiet shows nothing
  until it writes again or exits.
- Do the same, and also emit a held tail after a short quiet period, measured with an injected clock. A lone partial
  line still shows. A line split by a slow writer can still split if the pause outlasts the period.

Either way, `testOfferSaysWhenTheBufferWasEmpty` (`StderrIngressTests.swift:69`) offers unterminated chunks and expects
each to show at once, so it changes with the fix. The transport must also flush the tail when stderr closes.

# The content-process usage reader claims a units change fails safe, but it would kill idle processes

**Status:** fixed 2026-11-23
**Fixed:** 2026-11-23
**Found:** 2026-11-22, during the UTERM-046 review
**Estimate:** small; one design decision, settled on 2026-11-23. The reader calibrates its units, which keeps the
comment's fail-safe promise. The core-count guard below was rejected: a lightly busy unused process, inflated 41.7
times, still reads far below the core count, so the guard would not stop the false kill.

## Observed

The doc comment on `WebContent.usage` says that a release reporting processor time in nanoseconds would make a
spinning process read as idle. It says the watch would then "signal nothing rather than something wrong". The code does
the opposite. A closed tab's unused content process would read about 41.7 times busier than it is. Any such process
above about 1.2% of a core would cross the watch's half-core share and be signalled.

## Cause

`Packages/UnitermKit/Sources/BrowserApplet/WebContentProcess.swift:93-95` holds the comment. The reader multiplies the
reported time by `numer / denom` of the Mach timebase (`WebContentProcess.swift:110`). On Apple silicon that is 125/3.
Nanoseconds put through that conversion grow by 41.7, they do not shrink.

Confirmed by tracing the code and the Apple silicon timebase. No release has made this change, so it was not
reproduced. The 2026-11-23 triage re-read `WebContentProcess.swift` and confirmed the comment at lines 93-95 and
the conversion at line 113. `ClosedProcessWatch.expired` kills when `used >= busyShare * elapsed`, so an inflated
reading signals an unused process.

## Fix

Design call:

- Correct the comment to say the failure mode is false busy readings on unused closed processes. Accept that as the
  cost, since `killUnused` only signals a process no live tab uses.
- Add a guard. For example, treat a sample whose processor time outruns wall time by more than the core count as
  invalid, and signal nothing.

## Fix note

Fixed on 2026-11-23 by calibrating the units, a third option the triage added. `WebContentProcess.processorScale`
measures uniterm's own processor time once with `proc_pid_rusage` and with `getrusage`, and
`ProcessorTimeScale.calibrated` picks the Mach timebase or plain nanoseconds, whichever matches. When neither matches
within a factor of two, the scale is nil, `usage` reads nil, and the watch signals nothing. So the comment's promise
now holds: a units change reads correctly, and an unrecognized one fails safe. The comment now says so.

Files: `Packages/UnitermKit/Sources/BrowserApplet/WebContentProcess.swift`, and `ProcessorTimeScaleTests` in
`Packages/UnitermKit/Tests/BrowserAppletTests/BrowserHungProcessTests.swift`. Before the fix, a nanosecond reading went
through the 125/3 timebase, and a reading that matched neither scale was still converted. Both tests failed. A fourth
test checks that this machine calibrates to its own timebase.

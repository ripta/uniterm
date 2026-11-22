# The content-process usage reader claims a units change fails safe, but it would kill idle processes

**Status:** open
**Found:** 2026-11-22, during the UTERM-046 review

## Observed

The doc comment on `WebContent.usage` says that a release reporting processor time in nanoseconds would make a
spinning process read as idle. It says the watch would then "signal nothing rather than something wrong". The code does
the opposite. A closed tab's unused content process would read about 41.7 times busier than it is. Any such process
above about 1.2% of a core would cross the watch's half-core share and be signalled.

## Cause

`Packages/UnitermKit/Sources/BrowserApplet/WebContentProcess.swift:93-95` holds the comment. The reader multiplies the
reported time by `numer / denom` of the Mach timebase (`WebContentProcess.swift:110`). On Apple silicon that is 125/3.
Nanoseconds put through that conversion grow by 41.7, they do not shrink.

**Validation:** traced by reading the code and the Apple silicon timebase. No release has made this change, so it was
not reproduced.

## Fix

Design call:

- Correct the comment to say the failure mode is false busy readings on unused closed processes. Accept that as the
  cost, since `killUnused` only signals a process no live tab uses.
- Add a guard. For example, treat a sample whose processor time outruns wall time by more than the core count as
  invalid, and signal nothing.

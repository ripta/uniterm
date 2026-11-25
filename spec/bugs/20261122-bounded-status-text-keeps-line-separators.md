# Bounded status text keeps U+2028 and U+2029 line breaks

**Status:** fixed 2026-11-22
**Estimate:** small; no open design decisions.
**Found:** 2026-11-22, during the UTERM-048 review
**Fixed:** 2026-11-22

## Observed

A program-set status segment or `list-panes` field that holds U+2028 or U+2029 may keep the line break. A status
segment could then draw on two lines, though `StatusText.bounded` exists to keep such text on one line.

## Cause

`StatusText.bounded` (`Packages/UnitermKit/Sources/StatusKit/StatusText.swift`, about line 18) replaces scalars whose
general category is `.control` with a space. U+2028 is `.lineSeparator` and U+2029 is `.paragraphSeparator`, so that
check misses them. `isBidirectionalControl` (about line 46) does not list them either. `LaunchApprovalText.isUnsafe`
does list them, so the two helpers disagree.

## Repro

Call `StatusText.bounded("a\u{2028}b", maximumBytes: 64)`. Expected: `a b`. Suspected actual: the raw U+2028 stays.

## Fix

Treat `.lineSeparator` and `.paragraphSeparator` like `.control`, and replace them with a space.

## Fix note

`StatusText.bounded` now replaces `.lineSeparator` and `.paragraphSeparator` scalars with a space, as it does for
control characters. `StatusTextTests` reproduced the bug first and covers the fix.

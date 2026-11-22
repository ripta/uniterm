# Launch approvals and controller names draw zero-width scalars raw

**Status:** fixed 2026-11-22
**Estimate:** small; no open design decisions.
**Found:** 2026-11-22, during the UTERM-048 review
**Fixed:** 2026-11-22

## Observed

A program-chosen string with a zero-width scalar may draw identically to one without it. A launch approval for
`/usr/bin/l\u{200B}s` would then read as `/usr/bin/ls` in the Pending Requests window. Two controller names in the
Controllers window could look the same while their bytes differ.

## Cause

`LaunchApprovalText.isUnsafe` (`Packages/UnitermKit/Sources/WindowKit/LaunchApprovalText.swift`, about lines 71-79)
escapes C0 and C1 controls, line and paragraph separators, and bidi controls. It does not escape U+200B-200D, U+2060,
U+FEFF, or other default-ignorable scalars, so `escaped` passes them through. Its callers are the Pending Requests and
Controllers windows, through `ControllersWindowController.swift` and `ControllerReviewText.swift`.

## Repro

Call `LaunchApprovalText.escaped("/usr/bin/l\u{200B}s")`. Expected: the result shows the scalar, such as
`/usr/bin/l\u{200B}s`. Suspected actual: the result holds the raw U+200B and draws as `/usr/bin/ls`.

## Fix

Escape every scalar whose `properties.isDefaultIgnorableCodePoint` is true, beside the current set. Check that no
caller needs a default-ignorable scalar to join characters, such as U+200D in an emoji sequence. Such a name would then
draw as escapes. That is likely right for an approval, since the user must see every byte.

## Fix note

Triage run on 2026-11-22. A package test reproduced the bug: `escaped` returned U+200B, U+2060, U+FEFF, and U+200D raw.

`LaunchApprovalText.isUnsafe` (`Packages/UnitermKit/Sources/WindowKit/LaunchApprovalText.swift`) now also escapes every
scalar with `properties.isDefaultIgnorableCodePoint`. A joiner or variation selector in an emoji name now shows as an
escape. That is intended, since an approval must show every byte.

The regression test is `LaunchApprovalTextTests.testZeroWidthScalarsShowAsEscapes`. It failed before the fix.

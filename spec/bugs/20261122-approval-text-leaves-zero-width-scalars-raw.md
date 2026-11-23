# Launch approvals and controller names draw zero-width scalars raw

**Status:** open
**Validation:** not confirmed; found by reading the code during the UTERM-048 review, not reproduced in the app.
**Found:** 2026-11-22, during the UTERM-048 review

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

# An optimized build of the package crashes the Swift compiler in StatusKit

**Status:** open
**Found:** 2026-11-22, while timing the restore for the UTERM-051 review
**Validation:** reproduced with `swift test -c release`; not tried with `make CONFIGURATION=Release` or an archive

## Observed

`swift test -c release` in `Packages/UnitermKit` stops with "compile command failed due to signal 6". `swift-frontend`
reports a fatal error while it compiles the StatusKit module with `-O`. No optimized build of the package finishes, so a
Release app build may fail the same way.

## Cause

The compiler aborts in its SIL optimizer. The crash report says it was "running pass #92053 SILFunctionTransform
"CopyPropagation"" on `StatusQueue.present(level:source:text:record:showsMessage:raisesSignal:at:)`
(`Packages/UnitermKit/Sources/StatusKit/StatusQueue.swift:125`). The ownership verifier then fails in
`LinearLifetimeChecker`. This is a compiler bug, triggered by that function's shape. The toolchain is Xcode's default,
building for the macOS 26.5 SDK.

## Repro

Run `caffeinate -dimsu swift test -c release --filter <any test>` in `Packages/UnitermKit`. Expected: the build
finishes. Actual: the StatusKit compile aborts with signal 6, and the build is cancelled.

## Fix

Not settled. The options are to reshape `present` until the pass no longer crashes, or to mark it `@_optimize(none)`
with a comment that names the compiler bug. Either way, report the crash to the Swift project with the reduced function.
First check whether `make build CONFIGURATION=Release` hits it too. If it does, Release builds of the app are broken.

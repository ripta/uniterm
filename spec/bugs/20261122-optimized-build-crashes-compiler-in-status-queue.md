# An optimized build of the package crashes the Swift compiler in StatusKit

**Status:** fixed 2026-11-22
**Fixed:** 2026-11-22
**Estimate:** medium; one non-trivial decision. The crash is not limited to one function, so a per-function fix may not end.
**Found:** 2026-11-22, while timing the restore for the UTERM-051 review

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

## Investigation notes

Triage run on 2026-11-22.

- It still reproduces. `swift build -c release --scratch-path .build/swiftpm-release` in `Packages/UnitermKit` fails
  with "compile command failed due to signal 6". The frontend dies in `CopyPropagation` on
  `StatusQueue.present(level:source:text:record:showsMessage:raisesSignal:at:)`.
- The toolchain is Apple Swift 6.3.3 from Xcode, building for the macOS 26.5 SDK.
- A Release build of the app, through `make build CONFIGURATION=Release`, was not tried. It needs the Ghostty build.
  Run it before choosing a fix, since it tells whether Release app builds are broken too.
- No test can cover this. A unit test runs in a debug build, which never reaches the optimizer pass. The check is
  that the package builds with `-c release`.
- The function mixes an early `guard`, a `first(where:)` closure, a `first { }` closure in a `??` expression, and
  struct construction. Which of these trips the ownership verifier is not known.
- Fix options. Reshaping `present` is not known to work until a release build passes. `@_optimize(none)` on `present`
  is certain to work and costs nothing measurable on a function that runs once per status message.

### Fix attempt, same day

- Reshaping `present` fixed that function. Taking the closures out, un-shadowing `source` and `text`, and moving the
  on-bar half into its own helper together let StatusKit compile with `-O`. Closures and shadowing alone did not. The
  edit was reverted, since it does not fix the build alone.
- The next release compile then crashed in the same pass, on `HistoryPanelView.tableView(_:viewFor:row:)`
  (`Packages/UnitermKit/Sources/WindowKit/HistoryPanelView.swift:463`). So the compiler bug is not specific to
  `present`. More functions may sit behind that one.
- `swift build -c release -Xswiftc -Xllvm -Xswiftc -sil-disable-pass=copy-propagation` completes the whole package in
  37 s. The pass is the whole trigger.
- The user chose to disable the pass for the package over fixing function by function.

## Fix note

`Packages/UnitermKit/Package.swift` now adds `-Xllvm -sil-disable-pass=copy-propagation` to every Swift target, for
release builds only. Debug builds are unchanged. After the change, `swift build -c release` in the package and
`make build CONFIGURATION=Release` both finish. Before it, `make build CONFIGURATION=Release` also failed in the same
pass, so Release app builds were broken too.

No unit test can fail first, since a debug build never reaches the pass. The failing check was `swift build -c
release`, which crashed the compiler before the change. Remove the flag when a toolchain no longer crashes. The compiler
bug was not reported upstream.

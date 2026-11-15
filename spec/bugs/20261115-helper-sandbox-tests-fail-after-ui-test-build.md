# The helper sandbox tests fail after a UI test build in the same DerivedData

**Status:** open
**Validation:** seen once, in a work-queue run on 2026-11-15. A `make clean` before `make test-helper-sandbox` made it
pass. No minimal repro was run.

## Observed

`make test-helper-sandbox` failed 4 of its 8 tests. The failing tests were
`testTheShippedHelperCannotOpenAFileByPathOrConnect` in the Text and Image viewer applet suites. Each one reported
"file: opened". The helper could open a file by path, which its sandbox should forbid.

The run came after an `xcodebuild build-for-testing` that used the same `.build/DerivedData`. A `make clean`, then
`make test-helper-sandbox`, passed all 8 tests.

## Cause

`codesign -d --entitlements` on the built `ImageDecoder` helper in DerivedData showed entitlements that are not in the
repo's sources. They were a read-only exception for `/` and the `testmanagerd` lookups that Xcode injects into a test
build. `make test-helper-sandbox` builds the app with plain `xcodebuild build` into the same DerivedData. That build
does not re-sign the helpers that the test build left, so the probes run against the test-injected sandbox.

## Repro

1. `make clean`
2. `xcodebuild ... build-for-testing`, with the Makefile's `XCODEBUILD` flags, or any `make test-app` run
3. `make test-helper-sandbox`

Expected: all 8 tests pass. Actual: the file-by-path probes report "file: opened".

## Fix

The helper sandbox tests must probe the helpers as they ship. This needs one design call. The options are:

- Build `test-helper-sandbox` into its own DerivedData folder, so a test build never touches its products. This costs
  a second full build.
- Have `test-helper-sandbox` check the built helpers' entitlements against the sources first, and fail with a message
  naming `make clean` when they differ. This keeps one build but stops being silent.
- Force the helpers to re-sign in the plain build. This depends on Xcode's build-for-testing behavior.

## Workarounds

Run `make clean` before `make test-helper-sandbox` whenever a UI test build ran since the last plain build.

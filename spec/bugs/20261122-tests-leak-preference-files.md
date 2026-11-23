# Tests leave tens of thousands of preference files in ~/Library/Preferences

**Status:** fixed 2026-11-22
**Fixed:** 2026-11-22
**Found:** 2026-11-22, during the UTERM-049 review

## Observed

`~/Library/Preferences` held 50,869 files with `uniterm` in their names on 2026-11-22. Among them were 10,974
`dev.uniterm.tests.<UUID>.plist`, 5,896 `uniterm.tests.<UUID>.plist`, and 3,060 `uniterm-openwith-<UUID>.plist`. Each
is 42 bytes, an empty property list. Every test run adds more. Listing or backing up the folder slows down, and
`cfprefsd` tracks every domain.

## Cause

Tests make a fresh defaults suite per test, such as `dev.uniterm.tests.\(UUID().uuidString)` in
`Packages/UnitermKit/Tests/ScriptHostTests/Support.swift` (about line 27), and `UserDefaults(suiteName:)` in many
`WindowKitTests` files. Some tests never remove the suite. Others call `removePersistentDomain(forName:)`, as
`UnsavedWorkTests.swift` (about line 25) and `QuitGuardTests.swift` (about line 31) do. That empties the domain, but
`cfprefsd` still leaves an empty plist on disk, which matches the 42-byte files.

## Repro

1. `ls ~/Library/Preferences | grep -c '^dev.uniterm.tests'`
2. Run `make test-package`.
3. Repeat step 1.

Expected: the same count. Actual: the count grows.

## Fix

Give tests a defaults store that never touches disk: an injected in-memory store behind the settings type, or one
fixed suite per test process that is cleared between tests and removed in a class teardown. Then delete the leaked
files once. The design call is which of the two, since `SettingsStore` takes a `UserDefaults` today.

## Triage

Confirmed on 2026-11-22. A `WindowKitTests` run alone added 58 files. The new names included `uniterm-window-test-`,
`uniterm-windowset-test-`, `uniterm-openwith-`, `uniterm-settings-` and `uniterm.tests.`.

Deleting the plist right after `removePersistentDomain(forName:)` is not enough. That call makes `cfprefsd` write an
emptied plist about 20 seconds later, after any unlink. `/usr/bin/defaults delete <suite>` leaves no write pending.

## Fix

Every package test now gets its suite from `TestDefaults` in the new `DefaultsTestSupport` target, and calls
`discard()` at teardown. `discard()` runs `defaults delete`, removes the domain, then deletes the plist.
`TestDefaultsTests` makes 30 suites, discards them, waits 25 seconds, and checks no plist remains. It failed with 30 of 30
left on the unlink-only helper.

`OpenWithTests` also removed the domain from `UserDefaults()` instead of its suite, so it never cleaned up. It now
discards its suite too.

The files leaked before the fix stay in `~/Library/Preferences`. Deleting them is a one-time manual step. Each leaked
name ends in a UUID, so check a pattern against the app's own domains before deleting by it.

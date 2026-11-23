# Tests leave tens of thousands of preference files in ~/Library/Preferences

**Status:** open
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

**Validation:** the counts and sizes were confirmed. Which tests make the `uniterm.tests.` and `uniterm-openwith-`
names was not traced.

## Repro

1. `ls ~/Library/Preferences | grep -c '^dev.uniterm.tests'`
2. Run `make test-package`.
3. Repeat step 1.

Expected: the same count. Actual: the count grows.

## Fix

Give tests a defaults store that never touches disk: an injected in-memory store behind the settings type, or one
fixed suite per test process that is cleared between tests and removed in a class teardown. Then delete the leaked
files once. The design call is which of the two, since `SettingsStore` takes a `UserDefaults` today.

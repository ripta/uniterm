# A newer policy file that holds a boolean, null, or fraction is moved aside as broken

**Status:** open

## Observed

A later uniterm may write a policy file whose format is above 1 and that holds a boolean, a null, a negative number,
or a fraction anywhere in it. This build should leave that file alone as newer. Instead it treats the file as broken.
It moves the file aside and starts a fresh, writable one. When the newer build runs again, it finds the fresh file. Its
trust records sit only in the kept-aside copy, so they are lost unless the user recovers that copy by hand.

Nothing writes such a file today. The bug waits for the first policy format that uses one of those values.

## Cause

`ControllerPolicyFile.read` says it reads the format first, "so a newer file is told apart from a broken one whatever
else it holds" (`Packages/UnitermKit/Sources/ControllerTrust/ControllerPolicyFile.swift:70-71`). The format check runs
only after `StrictJSONReader.parse` succeeds (`ControllerPolicyFile.swift:64`). That reader refuses `true`, `false`,
`null`, negatives, and fractions (`Packages/UnitermKit/Sources/ControllerPackage/StrictJSON.swift:36-37, 89-90`). The
parse error becomes `.unreadable`, not `.newer` (`ControllerPolicyFile.swift:54-55`). The trust store moves an
unreadable file aside (`ControllerTrustStore.swift:147-155`), while it keeps a newer one read-only (`140-146`).

Traced in the code. Not reproduced with a test.

## Repro

Write a policy file `{"format": 2, "policies": [], "flag": true}` and start the app.

- Expected: the store reports the file as newer, keeps it, and saves nothing.
- Actual: the parse fails on `true`, the file is unreadable, and the store moves it aside.

## Fix

Widen the strict reader to the full JSON value grammar, giving booleans, null, and every number outside today's
integer domain their own cases. UTERM-022 settles this in "How the spec is decoded", so its M1 fixes this bug. The fix
needs no other design call. A regression test writes the repro file and expects `.newer`.

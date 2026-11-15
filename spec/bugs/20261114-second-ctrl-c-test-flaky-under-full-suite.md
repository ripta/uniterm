# The second-Ctrl-C test sometimes sees the first Ctrl-C end the script

**Status:** open
**Validation:** not confirmed. Seen once in a full package run. It passed alone and in another full run.

## Observed

`ScriptLimitsTests.testASecondCtrlCEndsAScriptStuckInACallTheInterruptNeverReaches` failed once during a full
`swift test` run of the package on 2026-11-14. Both of its checks after the first SIGINT failed:

- `the first Ctrl-C ended a call the interrupt cannot reach` (`ScriptLimitsTests.swift:139`)
- standard error read `stuck-in-c.janet: interrupted`, not `interrupted again` (`ScriptLimitsTests.swift:146`)

So the first interrupt stopped the script, the way it does before the blocking read begins. The same test passed in a
full run about ten minutes earlier, on the same code. It also passed when its suite ran alone right after the failure.
The run's other changes were in the strict JSON reader, which this test does not use.

## Suspected cause

The test sends the first SIGINT once `waitUntilBlocked` reports the helper's main thread is blocked
(`ScriptLimitsTests.swift:129-131`). Under load, that check may pass while the thread is blocked somewhere other than
the read, such as writing the marker. The interrupt then lands before the read and ends the script at the call.

Not traced. A product race, where the interrupt hook reaches the read after all, is not ruled out.

## Next step

Read `waitUntilBlocked` and what it samples. Then run the full package suite several times and see whether the failure
recurs, and in which order.

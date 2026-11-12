# ADR-11: Deferred Applet Replies Never Hide Effects

**Status:** accepted
**Date:** 2026-11-11

## Context

An applet answers a command through `perform`, which replies at once. Its contract says a thrown error leaves the
applet unchanged, so a caller that sees an error knows nothing happened. Retry logic in scripts and drivers depends on
that promise.

UTERM-019 brought the first commands whose answers come later. A page event arrives when the page acts. A script's
promise settles when the page lets it, and a page `confirm()` can hold it indefinitely. A snapshot, a PDF, find in
page, and cookie calls all finish in a WebKit completion handler. The applet contract had to gain a way to answer
later.

A late answer can fail after the effect already happened. A revocation, a run end, or a closed pane fails every
pending reply. If the pending command had an effect, such as a script that submitted a form, the failure would claim
that nothing ran.

## Decision

An applet reply may be deferred only for a command with no effect. A command with an effect replies at once.

- A command that only waits or reads, such as waiting for the next events, may hold a pending reply. A failed pending
  reply then means nothing ran, as the contract promises.
- A command with an effect whose result comes later replies at once with a handle. Its result is kept under that
  handle and read by a separate command. A completion event names the handle.
- Revocation, run end, and pane close fail pending replies and free handles. They never report an effect as undone.
- An error an applet returns, from a deferred reply or an immediate one, still means nothing ran. A reply lost in
  transport after the command ran is separate: the wire's reply-lost kind already says the effect stands.

## Rationale

A caller decides whether to retry from the reply. If a deferred reply could fail after its effect, a script would
resubmit a form or run a side effect twice. A handle separates "the command ran" from "here is its result". The first
answer is honest at once, and the result survives an interruption. Deferring only reads keeps the existing contract
true without a new error kind that every caller must learn.

## Consequences

- An applet that adds a slow command with an effect must give it a handle, a result slot, and a completion event. A
  blocking reply is simpler to write, and it is not allowed.
- Result slots need caps and lifetimes, and the caller must discard handles it no longer needs.
- The applet contract carries two reply shapes: an immediate reply and a pending reply. Every caller, including exec
  drivers, matches replies by request ID.
- A script waits for an effect's result through events, so the dispatcher never parks an effect behind a dialog the
  same script must answer.

## Alternatives Considered

- **Defer every slow command.** A run-script would wait on its promise. A page dialog would deadlock it, and a failure
  after the effect would report nothing ran.
- **Defer, and let the applet report a failure after an effect as "effect stands".** Every caller must handle that
  from every deferred command, and the result is still lost.
- **No deferred replies at all, with polling.** Polling needs a timer in the script. The REPL does not run Janet's event
  loop, so a polling helper would never resume there.

## References

- [UTERM-019](../proposals/UTERM-019-browser-automation.md): "Commands that wait", "Large results"
- [UTERM-001](../proposals/UTERM-001-foundation.md): the applet contract
- [ADR-05](ADR-05-applet-lifecycle-events-and-applet-responses.md): applet responses, which this extends with a
  pending reply
- [ADR-08](ADR-08-ui-responsiveness.md): a late answer arrives as a later event, never as a main-thread wait
- [ADR-09](ADR-09-control-authority-requires-authenticated-identity-and-explicit-scope.md): revocation fails pending
  replies and frees handles

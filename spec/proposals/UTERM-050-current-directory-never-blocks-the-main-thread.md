# UTERM-050: The Current Directory Never Blocks the Main Thread

**Status:** draft
**Created:** 2026-11-22
**Updated:** 2026-11-22

## Dependencies

- UTERM-001, for the applet contract and the pane tree
- UTERM-004, for `list-panes` and the new-pane and new-tab commands that read the directory

## Impacts

- UTERM-048 — M2 waits on this fix. Its settled decision "The current directory in the polled snapshot" names this
  work as its dependency. The panel shows whatever the fixed property returns, including an unknown state.

## Summary

An applet's `currentDirectory` stops checking the file system on the main thread. The rule goes into the applet
contract, so no applet can break it later. Each applet meets the rule in the way the design questions below settle.

## Motivation

Bug `20261122-terminal-directory-check-blocks-main-thread` records the problem. A shell can report through OSC 7 a
directory on a network mount that stopped answering. A viewer can also show a file whose folder sits on such a mount.
`currentDirectory` then calls `FileManager.fileExists` on that path, and the call does not return until the mount
times out.

Every reader of the property runs on the main actor. They are `list-panes`, a new pane or tab beside the applet, the
terminal's reopened tab and restore, and the open panel's starting folder. Each one can freeze every window.

ADR-08 says the main thread never waits on work whose duration uniterm does not bound. A check against a path the
user's shell or file chose has no bound. The terminal already moves its link checks off the main thread for this
reason. `currentDirectory` is the same kind of check, and it was missed.

The bug was found by reading the code. It was not reproduced, because that needs a mount that stops answering.

## Design Decisions (Settled)

None yet.

## Design Decisions (Open)

### Whether the rule covers every applet or only the terminal

The terminal checks a reported path. The data, map, text, and image viewers check the folder of their open file the
same way. The candidates are:

- Every applet follows the rule, and the contract's doc comment on `currentDirectory` states it. This is the plain
  reading of the bug.
- Only the terminal follows it. The viewers keep their checks, since a file the user opened is less likely to sit on a
  dead mount. This leaves the same freeze reachable from a viewer.

Recommended: every applet. The viewer case is the same defect, and a contract rule with exceptions is a rule nobody
can rely on.

### How an applet meets the rule

The candidates are:

- `currentDirectory` returns the path as the applet holds it, with no existence check. Each consumer that starts a
  process or opens a panel in it checks off the main thread, or lets the start fail and falls back. This is the plain
  behavior: the property does no file-system work at all.
- Each applet keeps a cached verdict on whether its path is a directory. The applet refreshes the verdict off the main
  thread when its path changes. The property reads the cache. A path not yet checked reads as unknown.

What each leaves open:

- The first leaves every consumer to decide what a missing directory means. A new pane started in a gone directory
  must fall back, and the fallback is a decision per consumer.
- The second adds state to five applets, and a stale verdict is possible between refreshes. It keeps the property's
  current promise, that a returned path is a directory.

### What `list-panes` reports for a path not yet checked

This follows from the previous question. With the first candidate, `list-panes` reports the path as held. With the
second, it reports the path only once the verdict says directory. The candidates for the second are to omit the field
or to report it marked unknown.

### How the rule is enforced

The candidates are:

- A doc comment on the contract's member only.
- A doc comment, plus one test per applet that injects an existence check which blocks, then reads
  `currentDirectory` on the main actor and expects it to return.

Recommended: the doc comment and the per-applet test. A comment alone does not stop the next applet from breaking the
rule, and the injected check already exists on the terminal.

## Risks

- **A consumer starts a process in a directory that is gone** — likelihood: medium, impact: low.
  Mitigation: the settled approach names the fallback for each consumer, and a test covers each one.
- **A cached verdict is stale after the mount changes** — likelihood: low, impact: low. Only the second approach has it.
  Mitigation: the next path change or the consumer's own start refreshes it.

## Milestones

### M1: Remove the main-thread check

**Status:** NOT STARTED

The milestone's checks depend on the open questions above. They are filled in when the questions settle.

- No applet's `currentDirectory` does file-system work on the main thread
- The contract's doc comment on `currentDirectory` states the rule

## Decision Log

- 2026-11-22: Filed as a draft from the triage of `20261122-terminal-directory-check-blocks-main-thread`. The bug's two
  fix options are carried as the open question "How an applet meets the rule".

## References

- ADR-08: UI responsiveness
- `bugs/20261122-terminal-directory-check-blocks-main-thread.md`
- UTERM-048: Pane Inspector, whose M2 depends on this

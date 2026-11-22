# ADR-15: A Program's Operation Is the User's Operation

**Status:** proposed
**Date:** 2026-11-21

## Context

Programs act inside uniterm. A script, a controller, or a driver can do much of what the user does by hand: open
things, move things, type, click, and navigate.

A program never acts on its own account. The user ran it, or approved it, to do something on their behalf. Every
action it takes traces back to that choice.

uniterm once treated a program's action as an unchosen change and handled it apart from the same action by the user.
That made the same action mean different things depending on who started it. Each difference guarded one case and left
its neighbors open, so the guards kept multiplying. That rule was retracted.

## Decision

A program's operation is the user's operation, carried out through the program. It behaves exactly as the user's
operation does. The only thing kept apart is authority: whether the program may act at all.

- An action means one thing, whoever starts it. Its effects, what it shows, what it asks, and what it leaves behind
  are the same.
- Whether a program may act is decided before it acts, by authority. Once a program may act, its action is not
  weakened, delayed, or hidden.
- A rule that applies to every source applies to programs because it applies to the user. That is not a special case.
- uniterm's own work when a program's permission ends is not the program's operation, so this rule does not govern
  how that work behaves. It still treats what the program left the way it treats what the user left.
- An operation a program performs that has no user counterpart has no user behavior to match.

## Rationale

The user delegated the action. A program does what the user asked it to do. Treating its action as less than the
user's second-guesses a choice the user already made, and leaves the work half done.

The user keeps one model of the app. When an action behaves the same whoever starts it, the user can predict what a
program will do, and can recognize its results afterward. A program's work never looks different, goes missing, or
disappears at the next launch because of who did it.

Safety belongs at the decision to let a program act. A program that should not do something should not be allowed to
do it at all. Weakening an action that was allowed protects only the cases someone anticipated. It looks like a
safeguard without being one, and every gap it leaves needs another patch. Putting safety in authority keeps it in one
place, where it can be complete.

Automation stays faithful. What the user does by hand, a program can repeat, and what a program does, the user can
reproduce by hand. A workflow behaves the same whether it is scripted or done by hand.

## Consequences

- A program's action can move the keyboard or change what the user sees while the user is working, as the user's own
  action would. The protection against an unwanted program is to not let it act, not to blunt what it does.
- Every safety question about programs becomes a question about authority. That puts more weight on getting
  permissions, approval, and scope right.
- Features need one behavior per action. A capability that only programs use must still be one the user could
  meaningfully perform, or it has no user behavior to match.

## Alternatives Considered

- **Treat a program's change as unchosen, and keep it inert or out of the way.** Each guard covered one case and left
  its neighbors open. The result was an app that behaved differently depending on who acted, without being safe.
- **Decide case by case.** Every feature would re-argue the same question, and the answers would drift apart.

## References

- [ADR-12](ADR-12-unchosen-changes-never-move-focus-or-arm-input.md): retracted, replaced in principle by this ADR
- [ADR-14](ADR-14-a-controller-controls-what-it-opened.md): authority, the one thing kept apart
- UTERM-036, UTERM-037, UTERM-038: work that applies this principle

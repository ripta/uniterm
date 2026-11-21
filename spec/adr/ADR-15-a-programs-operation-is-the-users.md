# ADR-15: A Program's Operation Is the User's Operation

**Status:** proposed
**Date:** 2026-11-21

## Context

Programs act on uniterm. A script opens a pane or a tab, applies a layout, moves a map, or drives a browser tab. A
controller clicks and types into a page. Each of these is an operation the user can also perform by hand.

ADR-12 made a program's change behave differently from the same change by the user. A program's pane took no focus,
its tab opened unselected, its commands were refused while the user held the keyboard, and its moves were not saved.
Every such rule grew its own exceptions, and each one left the program's result unlike the user's. ADR-12 was retracted
on 2026-11-20.

What a program may do is a separate question. ADR-14 settles it: a program acts only under an authenticated, explicit
grant, and only on what it opened.

## Decision

A program's operation is the same operation as the user's, and it behaves the same way. Only authority is kept apart.

- When a program performs an action the user can perform, it runs the user's code path for that action. Nothing is
  added or removed because a program asked. Focus, selection, raising a window, questions the user's action asks,
  refusals, saving, and what restore keeps all follow the user's action.
- Authority stays separate, per ADR-14. Permissions, grants, approvals, and "a controller controls what it opened"
  decide whether a program may act. They never change how the action behaves once allowed.
- A rule that applies to every source equally is not a special case. A scheme no source may load, a gate that filters
  the system's own reports, and a sheet that blocks every pane action apply to the program because they apply to the
  user.
- Cleanup that uniterm itself runs when a grant ends is not a program's operation. It has no user counterpart, so it
  follows its own rules. It still treats what the program left the way it treats what the user left.
- Where a program's operation has no user counterpart, such as reading a tab's address, there is nothing to match.

## Rationale

The user expects one behavior per action. A pane that opens is a pane that opened, whoever opened it. Splitting an
action by its cause multiplied edge cases, and each one left the program's result unlike the user's. Keeping authority
as the single difference puts every safety question in one place: whether the program may act at all. ADR-14 already
answers it at the effect boundary.

## Consequences

- A program's open, layout, or command can move the keyboard while the user types, as the user's own open does.
- New program-facing features reuse the user's paths. A review that finds a program-only branch treats it as a defect
  unless it is authority.
- Implemented features built under ADR-12 are corrected through follow-up proposals, not by editing their frozen text.

## Alternatives Considered

- **Keep program changes inert, as ADR-12 did.** Each special case left a neighbor open, and the user rejected the
  approach.
- **Decide per feature.** Every proposal would re-argue the same question, and the answers would drift apart.

## References

- [ADR-12](ADR-12-unchosen-changes-never-move-focus-or-arm-input.md): retracted, and replaced in principle by this ADR
- [ADR-14](ADR-14-a-controller-controls-what-it-opened.md): authority, the one thing kept apart
- UTERM-036: a program's opens and layouts take focus as the user's do
- UTERM-037: a controller's browser commands act as the user's
- UTERM-038: a program's map move and browser seed act as the user's

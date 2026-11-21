# UTERM-037: A Controller's Browser Commands Act as the User's

**Status:** accepted
**Created:** 2026-11-21
**Updated:** 2026-11-21

## Dependencies

- UTERM-005, for the browser's remote commands

## Impacts

- UTERM-005 — "Control": the bullets that commands never take keyboard focus, that navigation is refused on a focused
  tab or a tab with unsent input, that controller reload, back, and forward never resubmit a form, and that a download
  or app handoff in a controller tab asks first. Superseded in part.
- UTERM-005 — M8: the checks for those bullets. Superseded in part.

## Summary

A controller's browser command is the same operation as the user's. Open, navigate, reload, back, forward, and select
behave exactly as the user's New Tab, typed address, toolbar buttons, and tab click do. Only authority stays separate:
the two browser permissions, and acting only on tabs the controller opened.

## Motivation

ADR-12 was retracted on 2026-11-20. A program's operation is the same operation as the user's, and it behaves the same
way. UTERM-005 M8 was built the same day, to text written before the retraction. Its commands act differently from the
user's same action in several places. They never take the keyboard. They are refused on a focused tab and on a tab
with a draft. They never ask to resend a form. A controller's tab asks before every download and every app handoff.
The user ruled that the retraction must be followed through, for all of these.

UTERM-005 is implemented, so its text is frozen. This proposal records the change and supersedes the affected parts.

## Design Decisions (Settled)

### Each command is the user's action

Decision: each browser command runs the code path of the user's matching action, with nothing added or removed for a
controller.

- `open` is the user's New Tab with the address typed into it. The tab opens where the user's New Tab opens it, is
  selected, and takes focus as the user's tab would after typing that address.
- `navigate` is the user's typed address in that tab. The address resolves as typed input does, including search and
  app handoff. A typed load's rules apply to its downloads.
- `reload`, `back`, and `forward` are the user's toolbar buttons on that tab. A reload that would resend a form asks
  as the user's does, through the tab's own rules for which tab may ask.
- `select` is the user's click on that tab.
- No command is refused because the pane holds the keyboard or the tab holds unsent input. The `key-focused` and
  `unsent-input` error codes go away.
- A controller's tab follows the same download and handoff rules as any tab. `mailto:` opens without asking, and a
  page's first downloads start without asking, as in the user's tabs.
- `read` is unchanged. It has no user action to match.

Rationale: a program's operation behaves as the user's. Each special case M8 built treated a program's action
differently from the same action by the user, so none of them stands. Chosen by the user on 2026-11-21.

### What stays

Decision: authority is unchanged. Browser navigation and browser read gate their commands. A command reaches only a
tab its caller opened, for the caller's live grant. The schemes that no source may load stay refused for a controller
too. The per-grant tab cap stays.

Rationale: authority decides who may act, not how the action behaves. The retraction is about behavior. The cap bounds
how much a program may open, which a user's hands bound on their own.

## Design Decisions (Open)

None.

## Risks

- **A program's command lands under the user's keys** — likelihood: medium, impact: medium. A controller's navigate on
  the tab the user is typing in discards the draft, and an `open` moves the keyboard to the new tab. Accepted: the user's
  own typed address and New Tab do the same, and a program's operation behaves as the user's.
- **A controller can start an app handoff** — likelihood: low, impact: medium. A `navigate` to an app's scheme asks as
  a typed address does, and `mailto:` opens the mail app without asking. Accepted: a typed address does the same, and
  the controller already needs browser navigation.

## Milestones

### M1: Commands act as the user's

**Status:** NOT STARTED

- `open` selects its tab and takes focus as the user's New Tab with a typed address does
- `navigate` resolves its address as typed input does, including search and app handoff
- `reload`, `back`, and `forward` run the tab's own actions, and a form reload asks as the user's does
- `select` selects as the user's click does, and is never refused
- No command is refused for a focused tab or unsent input, and the two error codes are gone
- A controller's tab downloads and hands off as any tab does
- Permissions, tab ownership, and the per-grant cap are unchanged
- UTERM-005 carries "Superseded in part by UTERM-037" markers on the replaced "Control" bullets and M8 checks

## Decision Log

- 2026-11-21: Filed after UTERM-005 M8 shipped behavior that rested on retracted ADR-12. The user ruled that the
  retraction must be followed through, for every place a controller's browser command behaves differently from the
  user's same action. The user chose a superseding proposal so UTERM-005's frozen text keeps a record of what M8 first
  shipped.

## References

- UTERM-005: the browser applet and its remote commands
- UTERM-036: a program's opens and layouts take focus as the user's do
- [ADR-12](../adr/ADR-12-unchosen-changes-never-move-focus-or-arm-input.md): retracted
- [ADR-14](../adr/ADR-14-a-controller-controls-what-it-opened.md): authority, which this proposal leaves unchanged

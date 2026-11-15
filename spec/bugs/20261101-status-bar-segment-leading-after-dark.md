# Status bar directory segment jumps to the leading edge after switching to Dark

**Status:** open
**Triaged:** 2026-11-14 (not reproducible; see investigation notes)
**Observed:** 2026-11-01, during the user's visual check of the foundation proposal

## Observed behavior

The status bar's applet segment shows a folder icon and the current directory, `~`. It normally sits at the trailing
edge of the bar. Right after the theme was switched to Dark in the Settings theme picker, it moved to the leading edge,
just past the bar's left padding.

- The window was restored from a saved layout. The segment was correctly placed after the restore. It moved only at the
  theme switch, the moment Dark was picked.
- No command had run in the window. No status message was showing, and the message history said "No messages yet".
- Switching System to Light did not trigger it. Only switching to Dark did.
- After it broke, these did not restore it: switching back to Light or System, running commands, moving the bar
  between top and bottom, and resizing the window.
- Opening a new pane restored it, and it stayed correct after that pane closed.
- Clicking the status bar worked whether the segment was placed correctly or not.

## Reproduction

None known. The user could not reproduce it on a fresh build, with a restored window or a new window from Cmd-N. Theme
changes, splits, pane and tab opens and closes, and moving the bar did not trigger it.

## What was tried

These all passed on the code at the time, so none of them covers the bug:

- A package test that drives the real window controller with a fake applet showing the folder and `~`. It switches the
  theme store to Dark, confirms the window's effective appearance became DarkAqua, and checks that the segment stays at
  the trailing edge.
- A scratch test of the status bar view alone. It covered applet segments added before and after the first layout, a
  theme change at several stages, removing and re-adding the applet segment, and the unseen-error and exit-code segments
  appearing and disappearing.
- A UI test that launches the app, waits for the `~` segment, picks Dark, Light, and System in Settings, and checks that
  the segment stays near the trailing edge.

## Analysis

The segment sat about 21 points from the bar's left edge in the screenshot. That is 10 points of padding, a message area
of zero width, and 12 points of stack spacing. So the message area collapsed, or the applet segment view absorbed the
slack.

Opening a pane rebuilds the status bar's segment views, which would explain why that clears it. This points at stale
constraint or hugging state in the applet segment view or the status bar's outer stack. That stack uses fill
distribution. The message segment hugs at default-low priority and the applet segment at default-high. Which view takes
the slack is the layout solver's choice. This is a hypothesis, not a confirmed cause.

## Next step

When it next appears, capture the frames and constraints of the status bar's stack and segment views in the live app,
before opening a pane. That shows which view took the slack.

## Investigation notes

Triage run on 2026-11-14.

- No regression test for this bug exists in the repo. The three attempts under "What was tried" were not kept.
- The existing `StatusBarTests` package suite passes on the current build. None of its tests switch the theme and check
  where the applet segment sits, so a pass says nothing about this bug.
- The report has no repro, so no further attempt was made. The UI test route needs a display and the Touch ID prompt.
- The cause is still the unconfirmed hypothesis under "Analysis". The next step is unchanged.

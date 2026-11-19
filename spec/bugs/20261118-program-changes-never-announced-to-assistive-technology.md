# A change a program makes is never announced to assistive technology, against ADR-12

**Status:** open
**Estimate:** medium; three open design decisions: what each announcement says, whether a non-key window announces, and which changes count (including a program's close).
**Validation:** not confirmed with VoiceOver; traced in code only.
**Found:** 2026-11-18, by the design critic reviewing the fix for a script-opened pane that took focus

## Observed

ADR-12's Consequences say an announcement to assistive technology replaces moving focus to an unchosen change. That
keeps the change visible to VoiceOver users. uniterm posts no such announcement. A pane, tab, layout, or window a
program opens now takes no focus, so a VoiceOver user hears nothing when it arrives.

UTERM-022 plans to announce a form's arrival "as Pending Requests does". Pending Requests announces nothing either.

## Cause

The only `NSAccessibility.post` in the sources is in `Packages/UnitermKit/Sources/SettingsKit/ActionSettingRow.swift:127`,
for a settings action's status. None of these paths posts one:

- A script's `open-pane`, in the scripted `openPane` in `WindowKit/MainWindowController.swift`.
- A routed open from a program, in `placeRouted` in `WindowKit/MainWindowController.swift`.
- A layout, in `WindowKit/MainWindowController+Layout.swift`.
- A new row in Pending Requests, in `WindowKit/PendingRequestsWindowController.swift`.

## Repro

Turn on VoiceOver. Leave the keyboard in a terminal. From a script, call `open-pane`.

- Expected: VoiceOver announces that a pane opened, and the keyboard stays put.
- Suspected: VoiceOver says nothing.

## Fix

Post `.announcementRequested` where each program-driven change lands. Name each design call:

- What each announcement says, such as the applet kind and who opened it.
- Whether an announcement goes out when the change lands in a window that is not key.
- Which changes count: a pane, tab, window, or layout opened by a program, and a new Pending Requests row. A
  program's close may need one too.

UTERM-022's line about Pending Requests should change once this is settled.

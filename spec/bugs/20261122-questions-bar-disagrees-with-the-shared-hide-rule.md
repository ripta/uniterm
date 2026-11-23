# The questions applet's tab bar disagrees with UTERM-041's shared hide rule

**Status:** open
**Validation:** not confirmed; traced by reading the code and UTERM-041 during the UTERM-053 review. Nothing was run.

## Observed

UTERM-041 says every applet other than the terminal and the browser publishes exactly one tab and has no bar. Its M1
makes the shared bar hide below two tabs. The questions applet has a bar, always shown at a fixed height, and one tab
per pending question.

Once UTERM-041 M1 lands, a pane with one pending question would hide that question's tab, while the bar's space stays.
An empty pane publishes one placeholder tab, so a bar that showed the published list would show a phantom tab with a
close button.

## Cause

- `QuestionsView` (`Packages/UnitermKit/Sources/QuestionsApplet/QuestionsView.swift`, about lines 50-53) pins the bar
  at `AppletTabBar.height` with no hide rule. `show` (about line 75) feeds it the requester names, which are empty for
  an empty book.
- `QuestionsApplet` (`Packages/UnitermKit/Sources/QuestionsApplet/QuestionsApplet.swift`, about lines 464-471)
  publishes one "Untitled" tab when the book is empty, and one tab per entry otherwise.
- UTERM-041 "How the host knows the tab bar is hidden" (about line 269) states the one-tab rule for every other applet.

## Repro

None run. After UTERM-041 M1: open one question in a questions pane. Expected: its tab shows, or the bar's space goes
with the bar. Suspected actual: the tab hides and the space stays.

## Fix

A design call on UTERM-041: the questions applet follows the shared hide rule and its view drops the fixed height, or
it keeps its always-shown bar and UTERM-041's rule names it. Under UTERM-053 the bar reads the published list, so the
empty book's placeholder tab also needs a rule.

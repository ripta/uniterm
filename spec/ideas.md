# Ideas

Future improvements worth keeping that are not proposals yet. An idea leaves
this file when a numbered proposal covers it.

## OAuth2 support: access and refresh tokens

uniterm obtains, stores, and refreshes OAuth2 tokens. This is the most important
idea here, and none of it exists today. It needs the authorization-code flow with
PKCE, a way to receive the redirect, token storage in Keychain, refresh before and
after expiry, revocation or sign-out, and a place to configure providers. Still
open: what uses the tokens, such as the browser, Janet scripts, or terminal tools.

SSO belongs with this. Sites' own sign-in pages are a separate, smaller concern:
they run as ordinary pages and pop-ups in the browser, and none has been tried
against a real provider. Risks there, none tested in uniterm yet: providers that
reject embedded browsers, as Google does based partly on the user agent; WebKit's
block on third-party cookies, which can break SSO flows that use a hidden iframe;
and passkeys, which need Apple entitlements.

## Browser: microphone and camera support

The browser rejects every microphone and camera request, so video calls and
voice features do not work. Real support needs usage strings in the app, a
per-site question, and a recording indicator. The strings make WebKit expose the
native API and ask macOS before the browser's permission delegate, and the
stand-in `navigator.mediaDevices` script has to go. What a page sees after someone
answers the macOS prompt has not been measured.

## Browser: manage profiles

Add, list, and remove profiles, and switch between them. Every browser pane
shares one default profile today. The profile button's popover is the expected
home for these controls. A second profile needs its own website data store, and
its ID would flow through the pane's description.

## Browser: custom search engines

Let the user add a search engine of their own. The search engine setting offers
a fixed list today.

## Browser: history in the address bar

Suggest pages from the user's history while typing in the address bar. The
browser keeps no history across tabs today, only each tab's own back and
forward list.

## Browser: file upload pickers

Let a page's `<input type=file>` open a file picker. An upload input does
nothing today, so sites that take a file upload do not work.

## Browser: HTTP login dialogs

Ask for a username and password when a server requests HTTP authentication. The
browser answers no such request today, so a page behind a basic-auth login shows
the server's own 401.

## Browser: custom URL scheme

Let a scheme such as `corp://` serve pages through a `WKURLSchemeHandler`. This
is the least settled idea here, and no use for it is decided yet. A Janet script
is the most likely thing to serve it, which would make it wait on Janet
scripting. Still open: who defines a scheme, and what a scheme page can reach,
including whether ordinary web pages can link to it.

## Terminal: call out a bell

When a terminal rings its bell, call out its pane and its tab. A highlight is one
option, and the form is still open.

## Terminal: Kitty clipboard protocol

Support the Kitty clipboard protocol, OSC 5522, which libghostty handles from
Ghostty 1.4. uniterm denies its reads and writes today, and the program gets an
`EPERM` reply. A paste-event listing is the one part served now. When a program
turns on Kitty paste events, libghostty turns the user's own paste into a request
for the clipboard's type names, and uniterm answers it so the paste keeps working.

The protocol goes further than OSC 52 in several ways:

- A read or write can carry several MIME types, such as an image beside its text.
  uniterm reads and writes only plain text today.
- A request can name the primary selection. macOS has none, so uniterm reports it
  as unsupported.
- A program can name itself and ask to be remembered for the session. The
  permission prompt would show that name, and a remembered grant would skip later
  prompts.
- A write can be large. libghostty caps one write at 64 MiB by default.

UTERM-004's per-session clipboard policy and ADR-09's clipboard powers cover OSC
52 today. Support would need them to cover Kitty requests too.

## Screenshot of a pane or tab

Take a screenshot of the current browser tab, and of the current pane or tab of
any applet. Nothing here has been tried yet. The browser can use `takeSnapshot`,
though a full-length page needs more work. AppKit's view capture should cover
ordinary views, and will likely miss web, map, and Metal content. The terminal is
the open question: its Metal drawing needs a libghostty call, if one exists. A tab
that is not showing may have nothing current to capture.

Chosen so far. Each applet handles its own screenshots through an optional method
on the applet contract, since capturing the screen would need Screen Recording
permission. An applet with no method does not offer the command. AppKit capture is
a shared helper that an applet opts in to, never an automatic default, since it
would save a blank area for content it cannot see. A screenshot of a tab is just
the tab's content. A screenshot of a pane includes the pane's chrome, such as its
tab bar and toolbar, and leaves out the host's frame around the pane, such as the
focus border.

## Reorder tabs within a pane

Drag a tab to a new place in its own pane's tab bar. This covers one pane only.
Tabs cannot be reordered today. The gesture belongs in the shared `AppletTabBar`,
and each applet with tabs moves its own tab. The applet contract does not change.
Saving a layout already writes tabs in their current order. The selection is a
position, so a move has to keep the same tab selected.

Move Tab Left and Move Tab Right commands would give the palette a keyboard route.
They need no default shortcut. Tabs past the edge of a full bar are clipped, so a
drag cannot reach them.

## Move tabs between panes

Drag a live tab from one pane to another of the same type. The work starts with a
spike, then a proposal. The spike moves a live terminal surface and a live web
view between panes in one window, and watches for rendering, focus, and video
problems. Nothing has been tried yet, and only this could rule the idea out.

The proposal covers terminals first, since they hold far less state, then browsers
and any other applet with tabs. It changes the applet contract: a pane gives up a
tab and another adopts it. Rebuilding a tab from its description is no substitute,
since that kills the shell and reloads the page.

Still open for the proposal:

- Browser downloads, pending dialogs, and the script-opened tab limit belong to the
  pane. Opener links can end up pointing at a tab in another pane.
- Dragging a pane's last tab away should close the pane with no question and no
  undo entry. That path does not exist today.
- What undo means after a move.
- Moving between windows, since close stamps are per window.
- Control and trust in UTERM-004 depends on which pane a process runs in, so a move
  has to deal with existing grants.
- Browser profiles from the idea above fix a web view's data store at creation, so
  a live move between profiles has to be refused.

## Scriptable sidebar

A sidebar that scripts can program. It is a UI component, the way the palette and
the status bar are, and not a pane. Each window has at most one, and the user can
set it to the left or the right. This is not well fleshed out yet. It would come
after uniterm has proper scripting support.

The sidebars in the map viewer and the text viewer plans are a different thing:
each belongs to one applet and lives inside its pane.

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
per-site question, and a recording indicator. It also needs an answer to why a
request never reaches WebKit's permission delegate today. That stall was seen
under `swift test` and in the running app, and its cause is unknown.

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

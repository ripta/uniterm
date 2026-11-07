# Ideas

Future improvements worth keeping that are not proposals yet. An idea leaves
this file when a numbered proposal covers it.

## Browser: OAuth2 and SSO sign-in

Make OAuth2 and SSO sign-in work reliably. This is the most important idea here.
These flows run as ordinary pages and pop-ups, which the browser supports, but no
real sign-in has been tried against a real provider. Known risks, none tested in
uniterm yet: providers that reject embedded browsers, as Google does based partly
on the user agent; WebKit's block on third-party cookies, which can break SSO
flows that use a hidden iframe; and passkeys, which need Apple entitlements. A
provider that refuses the web view may need `ASWebAuthenticationSession`.

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

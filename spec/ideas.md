# Ideas

Future improvements worth keeping that are not proposals yet. An idea leaves
this file when a numbered proposal covers it.

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

# uniterm

uniterm is a unified terminal emulator for macOS. It goes beyond a plain terminal.

A window holds a tree of resizable split panes. Each pane runs one applet. Planned applets include a terminal, a
browser, a data viewer, an image viewer, a text viewer, a map viewer, and a REPL. The REPL scripts uniterm itself in
Janet, a Lisp.

Each window also has a status bar and a command palette. Both can be docked in different places.

## Status

Early development. The terminal applet runs through libghostty, with tabs and a program mode. A window holds splits that
can be resized, and the app opens several windows. It has a status bar with message history, undo for a closed pane, and
close guards for running programs. Every window's layout is saved and restored across launches. A data viewer opens
CSV, JSON, and `.xlsx` files as tables that sort, filter, and search. The other applets and the command palette are not
built yet.

## Stack

- Swift, with AppKit for windows, panes, and applet hosting.
- SwiftUI for small views, such as status bar segments.
- [libghostty](https://ghostty.org) for terminal emulation.
- [Janet](https://janet-lang.org) for scripting.
- [ZIPFoundation](https://github.com/weichsel/ZIPFoundation) for the ZIP container of `.xlsx` files. It is the only
  third-party Swift package. It is pinned to an exact version, and its notice ships in `Licenses/`.

## Building

Prerequisites:

- macOS 26 and Xcode 26.6 (build 17F113). Select it with `xcode-select`.
- The Metal toolchain: `xcodebuild -downloadComponent MetalToolchain`.
- The Command Line Tools with the macOS 15.4 SDK, only on a cold cache. The first build and every Ghostty upgrade need
  them. Zig 0.15 cannot link against the macOS 26 SDK, so the build compiles against that older SDK. The build
  downloads the Zig that `ghostty.pin` names into its own cache. It never uses or changes a Zig installed on the
  machine.

Commands:

- `make build` builds the pinned libghostty, then `uniterm.app`, into `.build/DerivedData`.
- `make run` builds, then runs the app in the foreground, so its logs and any crash show in the terminal.
- `make test` runs the CI gating checks, package tests, and app UI tests. UI tests need a logged-in desktop session
  and Accessibility permission for the terminal. `make test-ci` runs just the CI gating checks, without Xcode or Zig.
- `make fuzz` runs the table readers' fuzzer under the address sanitizer, in its own build folder. It tries
  `FUZZ_ITERATIONS` mutated inputs, 5000 by default. `make test-package` runs the same fuzzer at a small count. `make ci`
  does not run `make fuzz`.
- `make fmt`, `make fmt-check`, `make lint`, and `make check` format and check the sources.
- `make ghostty-offline-check` proves that the pinned libghostty rebuilds with the network off. It takes about four
  minutes, and `make ci` runs it.
- `make swiftpm-offline-check` proves that the Swift packages resolve and build with the network off. The versions come
  from the committed `Package.resolved` files and the sources from `.cache/swiftpm`. It takes under a minute, and
  `make ci` runs it. CI does not keep `.cache/swiftpm`, so a CI run fetches the packages once before the offline step.
- `make help` lists every target.

GitHub CI skips the macOS SDK and build/test jobs when all changed files are root-level Markdown or Markdown under
`spec/`. The lightweight `ci` check still reports a result. Markdown shipped in the app, such as files under
`Licenses/`, still triggers the full build. Manual workflow runs always build fully. Missing comparison history also
falls back to the full build.

`ghostty.pin` records the Ghostty commit and the toolchain that built it. The build fails when the downloaded Zig does
not match `ZIG_SHA256`, or when Xcode or the SDK differ from the pin. It also fails when the extracted Ghostty source does not
match `GHOSTTY_TREE_SHA256`, a hash over every file in the source tree. To bump the pin, set `GHOSTTY_TAG` and
`GHOSTTY_COMMIT`, run `scripts/build-ghostty.sh tree-hash`, record its output as `GHOSTTY_TREE_SHA256`, then update the
toolchain fields.

The libghostty build, the pinned Zig, its package cache, and the artifacts live under `.cache/ghostty`. A rebuild of the pinned
commit needs no network once that cache exists.

## License

MIT. See [LICENSE](LICENSE).

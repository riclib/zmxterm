# zmxterm

A macOS terminal whose entire model lives in [zmx](https://github.com/neurosnap/zmx). The app owns no session state:
sessions are the truth, labels carry the layout, and `zsm` in any terminal sees
exactly what the app sees.

```sh
swift run zmxterm teamwall     # open a named tab
swift run zmxterm              # first tab found
swift run zmxterm --selftest   # headless tree tests, no window
```

## The model

There is no state file. Everything comes from `zmx list`, which returns labels
inline, so one call is the whole model.

| label      | meaning                                                        |
| ---------- | -------------------------------------------------------------- |
| `tab`      | which tab this pane belongs to. Defaults to the name before the first dot, so `spike-dev-1.shell` groups under `spike-dev-1` with nothing set. A team wall spanning several agents sets `tab=spike` explicitly. |
| `pos`      | slot in the tab's split tree — `v0.h1.v2`. Each segment is the parent's axis (`h` side by side, `v` stacked) plus a child index. |
| `size`     | share of the **whole tab**, 0…1. Panes that declare nothing split the remainder. |
| `state`    | `waiting` (wants you) or `failed`. Absent means resting.        |
| `ephemeral`| `1` marks a scratch pane. Naming it is what promotes it.        |

All of it survives zmx's label charset, which permits only `[A-Za-z0-9._-]` —
no JSON, no paths, no spaces. That constraint is why the layout is flat
per-session fields rather than a serialised tree, and the reason a killed
session takes its slot with it instead of leaving a dangling entry behind.

`size` is a share of the tab rather than of the parent split because an internal
node — a column of three panes — is not a session and has no label of its own.
Borrowing one from a leaf would make that leaf's number mean two things at two
levels. Whole-tab shares simply add up.

## Why it's built this way

- **Quit changes nothing.** There is no persistence code, because no layout
  lives in the app. Restore is: enumerate the socket directory, read labels, sort.
- **No control API.** An agent adds a pane with two shell commands and the app
  follows. Verified: `zmx run … -d` plus `zmx set … pos=v0.h1.v3` made a fourth
  pane appear in the right-hand column with the app untouched.
- **Closing a pane can't kill an agent.** Panes are attachments; `detach()`
  sends `.detach` and closes the fd. The session carries on.
- **`zsm` stays authoritative.** Anything this app can show that `zsm` cannot is
  state that ended up in the wrong place.

## Protocol notes

`ZmxClient` speaks the socket protocol directly rather than spawning
`zmx attach`. No subprocess means no client to outlive a closed surface — the
`zmx attach` route leaks one and pins the session's width to a ghost.

`Header` is a Zig `packed struct { tag: u8, len: u32 }`. That's 40 bits, but the
daemon moves it with `std.mem.asBytes`, which writes `@sizeOf` — and `u40` rounds
up to 8-byte alignment. **The wire header is 8 bytes, not 5**, with three padding
bytes after the length. A tight 5-byte header shifts every frame and the daemon
decodes plausible nonsense; it showed up as a 22×112 window resizing a session to
6144×20995.

`ipc.Resize` is `{ rows, cols, xpixel, ypixel }` as four little-endian `u16` —
rows before cols.

A client that never sends `.initialize` is a passive observer: the daemon only
sets `has_terminal_client` on `.Init`, so it streams `.output` without screen
replay and without counting as an attach. That's the mode for peek overlays and
for attention-watching panes that have no surface.

## Attention

Which pane needs you is reported by the pane, never inferred from its screen.
`bin/zmx-state waiting|failed|clear` writes the `state` label into whatever
session it is run inside — zmx exports `ZMX_SESSION`, so there is nothing to
configure per agent, per team, or per machine, and outside a zmx session the
script is a silent no-op.

Wire it to Claude Code hooks in `~/.claude/settings.json`:

```json
{
  "hooks": {
    "Stop":             [{ "hooks": [{ "type": "command", "command": "…/zmxterm/bin/zmx-state waiting" }] }],
    "Notification":     [{ "hooks": [{ "type": "command", "command": "…/zmxterm/bin/zmx-state waiting" }] }],
    "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "…/zmxterm/bin/zmx-state clear" }] }],
    "SessionStart":     [{ "hooks": [{ "type": "command", "command": "…/zmxterm/bin/zmx-state clear" }] }]
  }
}
```

Nothing here is Claude-specific — anything that can run a command can fill the
same label, and `Info` already carries `task_exit_code` for plain shells (not
yet read; `zmx list` doesn't expose it, so it needs an `.info` round trip).

Focusing a pane clears its `state`. The acknowledgement is a label rather than a
local flag, so a second window and `zsm` agree, and "I already saw that one"
survives a restart.

## Quota

The foot of the sidebar shows the account's five-hour, weekly and per-model
limits — three lines expanded, three pie wedges collapsed. White under 50%,
yellow to 75, orange to 85, red above.

These numbers are the account's, not the session's, so they are identical in
every Claude pane: a statusline per terminal spends a line of every pane saying
the same thing, and showing them once in the chrome gives that line back.

It is a reader, not a fetcher. `~/.claude/statusline.sh` already refreshes
`/tmp/claude/statusline-usage-cache.json` at most once a minute, so there is no
token to find, no API call to make, and no way for this app to spend anyone's
rate limit. The cost is that the file only moves while some Claude session is
rendering, so a cache nobody has refreshed in five minutes is dimmed rather than
presented as current.

## The rail

⌘B collapses the sidebar to icons — one row per pane, not per tab, because
vertical space is the plentiful axis on a tall screen and horizontal is the
scarce one. The gaps still carry the grouping.

Background is selection, foreground is state, so the two never collide:

| channel    | meaning                                                |
| ---------- | ------------------------------------------------------ |
| background | selected (lighter) vs not; a non-grey card means `failed` |
| foreground | dim = nothing to act on, colour = wants you            |

Colour is spent on state, so identity in the rail is glyph shape alone — the
icons have to read in monochrome.

## Layout and dragging

Pane frames are computed in one pass (`PaneLayout.compute`) rather than by a
recursive view where each split is a `GeometryReader` handing `.frame(width:)`
down. Nested readers cost a layout pass per level and settle over several
frames, so panes land on a sliver before reaching their real size — and each
intermediate is a real `.Resize` on the wire for every client watching.

Frames are never animated. An implicit animation makes panes *chase* the
pointer during a drag instead of tracking it.

Divider drags stay local until mouse-up, then commit every leaf's share at once.
Committing during the drag would be a `zmx set` subprocess per mouse event.
Because `size` already means share-of-tab, the commit is just writing back the
numbers the layout computed.

The pane floor is in points, not a fraction: a proportional floor compounds
under nesting into slivers.

Resize is debounced by 120ms. SwiftUI settles a nested split tree over several
layout passes, and each intermediate size would otherwise be a real `.Resize`
reflowing the session for every other client watching it.

## Files

```
ZmxProtocol.swift   frame encoding, tags, the 8-byte header
ZmxClient.swift     one socket, one session; attach / detach / resize / input
ZmxRegistry.swift   `zmx list` → model, socket-dir watch + 2s label poll
PaneTree.swift      `pos` labels → split tree
PaneLayout.swift    tree → frames, in one pass; divider drag math
PaneModel.swift     a surface bound to a session; PaneStore caches them
Views.swift         sidebar, rail, split canvas, pane chrome
SelfTest.swift      headless tree and drag tests
bin/zmx-state       the attention hook
```

## Not here yet

⌘K, peek overlays, per-pane process icons resolved from a `ps` tree walk, and
`task_exit_code` from `Info` so a plain shell that exits non-zero turns its card
red without any hook at all.

## Building

```sh
swift build            # no zig toolchain, no Ghostty checkout
swift run zmxterm      # needs zmx on PATH
```

Terminal emulation, PTY and Metal rendering come from
[Ghostty](https://ghostty.org) via
[libghostty-spm](https://github.com/Lakr233/libghostty-spm), which ships a
prebuilt `GhosttyKit.xcframework` as a Swift package. Session persistence is
[zmx](https://github.com/neurosnap/zmx). All three are MIT, as is this.

Agent icons and their licences are listed in
`Sources/zmxterm/Resources/icons/CREDITS.md`.

## Packaging

```sh
Scripts/package.sh                              # .app + signed + DMG
NOTARY_PROFILE=zmxterm Scripts/package.sh       # …also notarised and stapled
```

A SwiftPM executable is not an app bundle, so `Scripts/package.sh` assembles one
by hand — Info.plist, icon, and the SwiftPM resource bundle, which has to be
copied into `Contents/Resources` for `Bundle.module` to keep resolving. The
project stays a plain `swift build` with no `.xcodeproj` to drift out of sync,
at the cost of this script owning the plist.

It signs with a Developer ID certificate when one exists and falls back to a
development certificate otherwise, saying so — a development-signed bundle runs
on the machine that built it and is rejected by Gatekeeper everywhere else.

## Status

Pre-1.0 and built in a single sitting. The model is settled; the surface is not.
`swift run zmxterm --selftest` runs the headless tests — tree reconstruction,
divider maths, naming, label folding — none of which need a window.

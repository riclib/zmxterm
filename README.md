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

`ipc.Info` is 552 bytes and, unlike `Header`, an `extern struct`: C layout, so
natural alignment and tail padding. Nothing documents it, so the offsets were
read off hexdumps of live sessions and confirmed field by field against values
`zmx list` already prints. The table is in the doc comment on `ZmxInfo`, and
`--selftest` decodes a captured payload so a zmx release that moves a field
fails a test instead of quietly reporting a plausible wrong number.

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
same label, and a second source fills it with no hook at all: an `.info` probe
per session reads `task_ended_at` and `task_exit_code`, and a task that ends
non-zero writes `state=failed` on itself. Same label, same rendering.

That watcher only ever writes into an empty `state`. A zero exit clears
nothing — an agent's `waiting` means it needs a human, and a background build
finishing is not an answer — and it acts on a *transition*, never on a poll, so
a failure long past does not repaint itself red at every launch.

Two limits, both zmx 0.7.0's rather than ours, and both measured:

- Only `zmx run` tasks count. Task mode appends a `ZMX_TASK_COMPLETED:$?` marker
  and the daemon reads the status out of that; a command *typed* into the shell
  produces no marker and moves neither field. A typed `zig build` turning its
  pane red needs shell integration, which is a different feature.
- The exit code latches at a session's first task. Later tasks move
  `task_ended_at` and leave `task_exit_code` alone — run 3, 5, 7, 0, 3 down one
  session and it reads 3 throughout. `zmx wait` and the daemon's own log report
  the same stale number, so this is upstream's to fix; when it is, nothing here
  changes.

The second limit has a visible cost: in a session whose *first* task failed, a
later task that succeeded can still flag the pane. It can only ever write into
an empty `state`, so the worst case is a stale red on a pane nobody has looked
at, never a red over an agent's `waiting`. If it is noisier than it is useful
until zmx is fixed, turn it off — it takes effect on the next poll, not the next
launch:

```sh
defaults write land.liberato.zmxterm flagFailedTasks -bool false   # the .app
defaults write zmxterm flagFailedTasks -bool false                 # swift run
```

Focusing a pane clears its `state`. The acknowledgement is a label rather than a
local flag, so a second window and `zsm` agree, and "I already saw that one"
survives a restart.

## Reaping

Every split and every new tab writes `ephemeral=1`, and nothing used to remove
one, so scratch panes accumulated as real sessions forever. `ReapPolicy` decides
which of them are safe to destroy; it is a pure function of the session list,
two `ps`-derived facts and a `now`, so the whole thing is checked headlessly in
`--selftest` without a daemon and without killing anything.

**It is off unless you turn it on**, and there is no menu item, because the
consequence of a wrong reap is somebody's work gone with no undo:

```sh
defaults write land.liberato.zmxterm reapEphemeralOnLaunch -bool true   # the .app
defaults write zmxterm reapEphemeralOnLaunch -bool true                 # swift run
swift run zmxterm --selftest    # prints the verdict for every live session first
```

`ephemeral=1` with nobody attached only makes a pane a candidate. It is then
kept by any of: a `title`, a `state`, a label this build does not recognise,
anything running in it that isn't its own login shell, a `tab` label placing it
in someone else's wall, being younger than twelve hours, or a terminal that has
moved in the last twelve hours. Everything unknown — no `created` field, no
readable tty — keeps the pane too, so a `ps` that fails means nothing is reaped
rather than everything.

The last pane of a tab waits fourteen times as long, a week rather than half a
day. Taking it takes the whole tab, and a tab is a place you navigate to by
name rather than a slot in a layout — but that is a difference of degree, not a
reason for immunity. A tab nobody named and nobody used is the exact thing
`ephemeral=1` marks, so a policy that could never reap one would only ever tidy
walls.

Note what the age test is and is not. zmx has no "last touched" field, and the
session's socket does not have one either: a unix socket's mtime is set when it
is created and never moves again. The pty device node does move, on every read
and write through the tty, which is a real time of last I/O — but it cannot say
whether the bytes were a keystroke or a background job's output. Time since
creation, plus silence, plus nothing running, plus nobody attached is the whole
of what is actually known.

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

## The inspector

⌥⌘B collapses the right sidebar the way ⌘B collapses the left, and to a strip of
icons for the same reason. It holds panels about whatever the focused pane is
looking at — one so far — so the container is an enum of panels and a `switch`,
and the next one is a case rather than a rewrite.

The file tree roots at the focused pane's working directory and follows it.
Nothing polls: `TerminalViewState.workingDirectory` is `@Published` and
libghostty raises it on OSC 7, so a `cd` in the pane is an update in the
sidebar and there is no `pwd` probe anywhere in this app. A session created
outside it, by a shell with no integration, never reports one — that tree shows
`start_dir`, which zmx recorded when the session was made. Showing where a pane
started is worse than showing where it is, and much better than showing nothing.

Directories are read one level per expansion and never on the main thread: a
tree rooted on a network mount must not be able to stop the terminal from
drawing. Expansion resets when the root moves, there is no pinning, and there is
no filesystem watcher — a file created in the pane appears when you press
refresh.

Double-clicking a row types its path into the pane. No newline, one trailing
space, relative when the file is underneath the pane's directory and absolute
when it is not, single quoted when it holds anything a shell would read.
Inserting is deliberately not executing. The rule is `FileTree.insertion` and it
sits apart from the gesture, because dropping files from Finder has to produce
the same string.

None of what is open is session state, which is the one rule: it describes a
filesystem, `zsm` has no opinion about it, and it is nobody's label. What
persists is whether the sidebar is open and how wide it is, in `@AppStorage`
beside `railCollapsed`.

## The reader

Right-click a file in the tree and **Open in Reader** runs a viewer on it. A
reader is **a pane whose job is to show a thing, where the thing's type picks
the command**: a `.md` opens in `mdv --watch`, which renders markdown, its
mermaid diagrams and live reload with the kitty graphics protocol; a `.log`
opens as a live tail; anything else falls to a pager. The graphics protocol
survives the whole chain — the viewer emits images, zmx's terminal emulation
carries them, and the libghostty surface draws them.

**A reader is a shell session running a viewer, marked `reader=1`** — not a
session whose process *is* the viewer, and not a native panel. That distinction
is the feature. With a shell underneath, the viewer can be stopped and started
again on a different document while the pane keeps its name, position, size,
scrollback and labels; a pane whose process was the viewer would have to be
killed and recreated for every file. And it keeps the one rule: a reader is an
ordinary zmx session, so `zsm` sees it, it survives quitting, and it restores
itself without this app remembering anything. The label is a bare flag, which
fits zmx's charset — the path lives in argv, where a path can actually live,
because a label could never hold one.

A tab keeps **one** reader. The second document replaces what the first is
showing rather than splitting the layout again, which is what a stable panel
means. The first Open in Reader in a tab splits a pane to the right and marks
it; after that they all land there. Any pane can be designated by hand from its
context menu.

Opening into a reader that already has a viewer up is two `.input` sends: the
rule's stop key, then the command line and a Return — the one place in this app
where a trailing newline is wanted. Two sends and not one, whatever the stop
key is: `^C` is a legitimate stop for a `tail` and SIGINT flushes the tty's
input queue, so a command line written after it in the same frame would go with
it. A viewer that ignores its stop key is signalled half a second later rather
than left wedging the pane, and only if the pid has not changed in the meantime.

**What is running in the reader is recognised by pid, not by name.** The pid is
the one the app watched start there, remembered in-process, and it is the only
thing that survives the two cases a rule list creates: a pipeline is several
processes under one shell, so the name that comes back is whichever the process
scan reached first rather than a fact about the rule, and a `tail -f`
never exits, so anything asking "is a viewer still running?" would call the pane
busy forever and refuse the next document. A pid answers both — if the
foreground process is the one we started, it is ours to stop, whatever it is
called and however long it runs. The memory does not survive a restart, and
afterwards a viewer left running in a reader is treated as somebody else's and
the pane refuses, which is the safe direction to be wrong in. It is not
persisted: it is not session state, and `zsm` has no opinion about it.

Double-clicking still inserts a path, for `.md` and everything else. Uniform
behaviour beats special-casing by extension, and a gesture whose meaning depends
on the file you aimed it at is one you have to think about first.

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
ZmxProtocol.swift   frame encoding, tags, the 8-byte header, `ipc.Info`
ZmxClient.swift     one socket, one session; attach / detach / resize / input
TaskWatcher.swift   `.info` poll; a failed task sets `state=failed` on itself
ZmxRegistry.swift   `zmx list` → model, socket-dir watch + 2s label poll
PaneTree.swift      `pos` labels → split tree
PaneLayout.swift    tree → frames, in one pass; divider drag math
PaneModel.swift     a surface bound to a session; PaneStore caches them
Views.swift         sidebar, rail, split canvas, pane chrome
FileTree.swift      where the tree roots, listing order, visible rows, path → text
InspectorView.swift the right sidebar, its panels, and the file tree's views
Reader.swift        the `reader=1` pane: the viewer rules, what gets typed, when it is stopped
ReapPolicy.swift    which scratch panes are safe to destroy; the launch pass
SelfTest.swift      headless tree and drag tests
bin/zmx-state       the attention hook
```

## Not here yet

⌘K, peek overlays, and shell integration — which is what a command *typed* into
a pane would need before it could turn that pane red, since zmx only sees the
exit status of a `zmx run` task.

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

## Configuration

Your Ghostty config, used as-is — `$XDG_CONFIG_HOME/ghostty/config`,
`~/.config/ghostty/config`, or the macOS Application Support path, in that
order. The surface is libghostty, so it parses exactly the file Ghostty parses:
no mapping layer, no subset to maintain, and a setting added to Ghostty tomorrow
works here without a release.

The file is watched, so edits apply to every open pane without a relaunch —
including the rename-over that most editors do rather than writing in place.
⇧⌘, forces a reload, the same binding Ghostty uses.

Settings that only mean something to a whole application — `keybind`,
`copy-on-select`, window chrome — are parsed and simply do not apply to an
embedded surface.

The reader's viewers are not in that file — they are nothing to do with
libghostty — and they are a list rather than a setting, which `defaults write`
is a miserable way to edit. They live in `~/.config/zmxterm/viewers.conf`
(or `$XDG_CONFIG_HOME/zmxterm/viewers.conf`), read afresh every time a document
is opened, so an edit applies to the next one with no reload and no watcher:

```
# patterns              command
*.md *.markdown         mdv --watch {path}
*.md *.markdown         glow -p {path}
*.log *.jsonl  quit=^C  hl -P --follow {path}
*                       bat --paging=always {path}
```

Ordered, first match wins, and the patterns are globs matched against the file's
name, case-insensitively. **A rule whose viewer is not installed falls through
to the next match** — no `mdv` and a `.md` opens in `glow`, or in `bat`;
degrading to a worse viewer beats degrading to nothing, which is also why the
same patterns appear twice above. A pipeline needs every binary it names, since
a pane opening onto `hl: command not found` is exactly the empty reader
this avoids.

The patterns are separated from the command by **two or more spaces or a tab** —
the gap is the delimiter, which is why a command can contain single spaces,
pipes and quotes without any escaping. `{path}` is where the file goes, quoted,
as many times as you write it; a command with no `{path}` gets it appended, so a
rule written the way #20's single `readerCommand` was still means what its
author meant. `quit=` in front of the command is how that rule is stopped —
`q` if it is not said, `quit=^C` for something that has no quit key, `quit=` for
something that stops for nothing and has to be signalled. It is the one word
treated that way: `TERM=xterm-kitty mdv --watch {path}` is still an environment
assignment for the shell, which is a real thing to want while a viewer detects
Ghostty by name.

**A line that cannot be read loses itself and nothing else**, and says which
line it was. That is deliberate and it is the opposite of what libghostty does
with its own config, where one bad key rejects the whole file. Only a file with
no usable rule left in it falls back to the built-in list above — and says that
too, once per run, in the same alert that explains anything else that stopped a
document opening.

The remaining switches are ordinary defaults, including #20's single viewer,
which still stands as an unconditional rule when there is no file:

```sh
defaults write land.liberato.zmxterm readerCommand "glow -p"   # superseded by the file
defaults write land.liberato.zmxterm readerQuitKey q           # empty: signal it instead
defaults write land.liberato.zmxterm flagFailedTasks -bool false
defaults write land.liberato.zmxterm reapEphemeralOnLaunch -bool true
```

A `swift run` build is not the bundle, so its defaults domain is `zmxterm`
rather than the bundle id.

The config is loaded with an empty `TerminalTheme`. The controller otherwise
overlays a light/dark palette *after* the file, which would silently override a
`theme =` line. The trade is that panes follow the config rather than the system
appearance, which is what someone who wrote a theme into their config already
asked for.

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

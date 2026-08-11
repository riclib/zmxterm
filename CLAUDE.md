# zmxterm

```sh
swift build
swift run zmxterm [tab]          # opens a named tab; no arg = first found
swift run zmxterm --selftest     # headless tests, no window, no zmx needed
Scripts/package.sh               # .app + signed + DMG
```

Read `README.md` first — it explains the model and why the odd parts are odd.
What follows is only what is easy to break without noticing.

## The one rule

**The app owns no session state.** zmx sessions are the truth, labels carry the
layout, and `zsm` in any terminal sees exactly what the app sees. Do not add a
state file, a tab database, or a cache of "current layout" — every one of those
can disagree with zmx, and the moment one does, quitting stops being free and
restore stops being `enumerate the socket directory, read labels, sort`.

Useful test when adding a feature: *could `zsm` show this?* If the answer is no,
the state is in the wrong place.

## Traps, each of which cost real time

**The zmx frame header is 8 bytes, not 5.** `Header` is a Zig
`packed struct { tag: u8, len: u32 }` — 40 bits — but the daemon moves it with
`asBytes`, which writes `@sizeOf`, and `u40` rounds up to 8-byte alignment. A
tight header does not error; it shifts every frame and the daemon decodes
plausible nonsense.

**`zmx run` is task mode.** It echoes the command, appends `ZMX_TASK_COMPLETED`
and runs under bash. Create shells with `zmx attach <name> < /dev/null`.

**`zmx list --where k=v` is advertised in `--help` and not implemented.** It
accepts the flag and returns everything. Filter with `grep`.

**zmx cannot rename a session** — the name is the socket path. A pane is renamed
with a `title` label; a *tab* really can be renamed, because its identity is the
`tab` label.

**Do not use `TerminalSurfaceView.terminalFocused`.** It is a two-way binding
whose push half calls `makeFirstResponder(nil)` on any update where the binding
reads false, including the update caused by the click that just focused the
pane — focusing then takes two clicks. `terminalFocusOnAppear` wraps the same
modifier. Focus is granted imperatively through `TerminalFocusProbe`, on
deliberate intent only.

**Never animate pane frames.** An implicit animation makes panes chase the
pointer during a divider drag instead of tracking it.

**Divider drags use the pointer's absolute `location`, never `translation`.**
A handle measured by its own translation reports in a coordinate space that
moves with it, and stutters. Commit `size` labels on mouse-up, never during —
committing per event would be a subprocess per frame.

**Clearing `state` is destructive**: it discards the one signal telling a human
an agent is waiting. It is guarded by app-active plus a settle delay, because
SwiftUI hands out focus during launch while the app is still inactive.

**One `TerminalController` serves every pane** (`TerminalConfig.controller`).
Panes differ in what they are attached to, never in how they are drawn, so a
per-pane controller would only be a way for them to drift. It is created with an
*empty* `TerminalTheme` on purpose: the controller otherwise overlays a
light/dark palette after the user's config, silently overriding their `theme =`.

**A config with `theme =` needs `GHOSTTY_RESOURCES_DIR`.** libghostty resolves
theme names against Ghostty's resources directory and finds it through that
variable, which a Ghostty-launched shell exports and the Dock does not — so the
config loaded when the app was started from a terminal and was silently rejected
otherwise. `TerminalConfig.locateGhosttyResources()` sets it. Note the failure
mode: one config diagnostic makes libghostty reject the *whole* file and fall
back to defaults, so a single unresolvable key loses every other setting too.

**A surface is destroyed and rebuilt on every tab switch**, while the client
under it stays attached — the model is cached in `PaneStore`, the view is not.
The new surface is empty, and output that arrived while it did not exist was
dropped, so something has to ask the daemon to redraw. `.Init` on an
already-attached connection does exactly that. The size is unchanged across a
tab switch, which is why `resize()` cannot be the trigger.

## Conventions

Labels accept only `[A-Za-z0-9._-]`. Fold user input with `Zmx.slug`.

`size` is a share of the **whole tab**, not of the parent split — an internal
node is not a session and has no label of its own, so shares have to add up.

Placeholder names come from `SessionNames`: Guide characters for tabs, because a
tab is something you refer to out loud; `shell-N` for panes, because a pane is
positional.

## Tests

`SelfTest.swift` runs without a window and without zmx, which is what makes it
worth running. Anything expressible as a pure function over sessions and labels
belongs there — tree reconstruction, drag maths, naming, slugging, icon rules.
Keep it that way; a test that needs a running daemon will not get run.

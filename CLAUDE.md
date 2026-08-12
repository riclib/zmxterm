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

**`task_exit_code` is only the *first* task's, and only for `zmx run`.** A
command typed into the shell writes no marker, so neither `task_ended_at` nor
`task_exit_code` moves at all. And zmx 0.7.0 latches the code: run 3, 5, 7, 0, 3
down one session and every reading is 3, while `task_ended_at` advances each
time. The daemon log and `zmx wait` repeat the same stale number, so it is not a
misread of the struct. `ZmxTaskWatch` is written for a daemon that reports
honestly and says so; don't "fix" it by working around this.

**`zmx attach` inside a zmx session switches that session instead of creating
one.** The client sees `ZMX_SESSION` and sends `.SwitchSession` to the daemon it
is already talking to, so a script creating test sessions from an agent's own
pane silently creates nothing — and yanks the human's pane elsewhere if the
target does exist. Prefix with `env -u ZMX_SESSION`.

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

**`ended` and `exit_code` are not labels.** They arrive in the same
tab-separated line as the labels, on any session that has completed a `zmx run`
task, and `zmx set <name> ended=` does not remove them — they are the daemon's
fields. `Zmx.list` reserves both, so they stay out of `labels`; before it did,
the app was inventing two labels nobody had set on every finished task.

That reserving has a consequence worth knowing, because it crosses two
features: while those fields *were* landing in `labels`, `ReapPolicy`'s "a label
this build does not recognise" veto fired on them, and a `zmx run` session was
accidentally unreapable forever. It no longer is. The veto still stands for
labels an orchestrator actually sets, which is what it was for; a finished task
is now judged on age, silence and the rest like anything else.

**Only one code path destroys a session nobody asked about.**
`EphemeralReaper.runOnLaunch`, called once from `applicationDidFinishLaunching`,
guarded by a `UserDefaults` flag that is off unless someone writes it. Keep it
that way: the decision itself is a pure function in `ReapPolicy` precisely so it
can be argued about in `--selftest` rather than on a live machine, and the
`--selftest` dry run must never gain a path to `zmx kill`.

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

## Working on a ticket

The ticket says what to build and why. This says how work happens here, so it
does not have to be restated in every hand-off.

**Work in a worktree, on a branch named for the ticket.** Never commit to
`master` and never push; whoever dispatched you integrates, and a push races
them. One commit per ticket, message ending `Closes #N`, body explaining *why*
in the style of `git log` — explanatory prose, not a changelog.

**You almost certainly cannot see the screen.** There is no screen-recording or
accessibility permission on this machine, so `screencapture`, `osascript` and
System Events all fail. You cannot click, drag, or press a key in the app. Do
not try. Say plainly in your report which claims are measured and which are
believed — a fix presented as certain that turns out wrong costs more than one
flagged honestly.

**So make the rules checkable instead.** `swift build && swift run zmxterm
--selftest` runs without a window or a daemon, which is the whole reason it gets
run. Anything expressible as a pure function belongs there. The count varies
between runs because some checks enumerate live sessions; the invariant is zero
failures. A temporary env-gated probe, run and then removed before committing,
is a legitimate way to prove something the tests cannot reach — several
features here were verified that way.

**Other people's sessions are live work.** This machine runs real agents in zmx
sessions alongside your test ones.

- Never `zmx kill` a session you did not create. There is no undo.
- Never relabel one you did not create. `pos`, `tab`, `size` and `title` are
  somebody's layout, and `state` is how an agent signals it needs a human.
- Never launch the app on a tab whose panes you did not make. Attaching resizes
  those sessions and reflows their output.
- Create test sessions under a prefix of your own and kill them when you finish:
  `cd /tmp && env -u ZMX_SESSION zmx attach qaNN.a < /dev/null > /dev/null 2>&1`.
  The `env -u` is not optional — see the `ZMX_SESSION` trap above.

**Do not release.** No tags, no notarisation, no touching
`/Applications/zmxterm.app`, no version bumps. Releases are cut deliberately.

# zmxterm

A macOS terminal for running **several coding agents at once** — and for not
having to watch them.

Every pane is a [zmx](https://github.com/neurosnap/zmx) session, which means the
work outlives the window showing it. Close the app mid-build and nothing stops.
Reopen it and the layout is back, because the layout was never in the app.

```sh
brew install neurosnap/tap/zmx          # the one requirement
open zmxterm-0.12.1.dmg                 # from Releases
```

## Why it is different

Most terminals own their tabs and panes, and persist them into a file of their
own. This one owns nothing. **zmx sessions are the truth, and the layout lives
as labels on those sessions.**

That single decision is where everything else comes from:

- **Quitting is free.** There is no persistence code, because there is nothing to
  persist. Restore is: list the sessions, read their labels, sort. Kill the app
  during a deploy and the deploy carries on.
- **Closing a pane cannot kill an agent.** A pane is a *view* of a session, not
  the session. Closing it detaches; the process never notices.
- **There is no control API, and agents drive it anyway.** An agent places its
  own pane with two shell commands — `zmx attach`, then `zmx set … pos=v0.h1`.
  The app is watching the same labels and simply follows. Nothing had to expose
  an endpoint, and nothing needs permission.
- **Any terminal sees the same workspace.** `zsm` in a plain SSH session shows
  exactly what the app shows, because they are reading the same thing. If this
  app could ever show something `zsm` cannot, that is state in the wrong place.

The terminal itself is [Ghostty](https://ghostty.org) — the real one, via
libghostty — so your Ghostty config is used as-is, including your theme, font
and background image. There is no settings screen to keep in sync with it.

## Running several Claudes

This is what it is for.

**Agents arrange themselves.** An orchestrator building a team wall writes six
labels and six panes appear, without the app being told:

```sh
zmx set spike.orc   tab=wall pos=v0.h0    size=0.30
zmx set spike.dev-1 tab=wall pos=v0.h1.v0 size=0.15
zmx set spike.dev-2 tab=wall pos=v0.h1.v1 size=0.15
```

**Panes say when they need you, instead of you reading their output.** An agent
writes one label when it stops, and its pane goes from grey to colour in the
rail — the whole signal, in a column you can take in at a glance:

```sh
zmx set "$ZMX_SESSION" state=waiting    # I have stopped and want a human
zmx set "$ZMX_SESSION" state=failed     # something went wrong
```

`bin/zmx-state waiting|failed|clear` does the same and is a no-op outside a zmx
session, so it is safe to wire into Claude Code hooks in
`~/.claude/settings.json` and forget about:

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

Looking at a pane clears its state, so "I have seen that one" is a fact about
the session rather than a flag in one window — a second window agrees, and it
survives a restart.

**Nothing here is Claude-specific.** Anything that can run a shell command fills
the same label, and a plain `zmx run` task that exits non-zero reddens its own
pane with no hook and no agent involved.

**An agent that dies does not take its work with it.** The session is the
process's home; the agent is a client of it. Restart the agent, `zmx attach` the
same name, and it is back where it was.

## Installing

**The app.** Download the `.dmg` from
[Releases](https://github.com/riclib/zmxterm/releases) and drag it across. It is
signed with a Developer ID and notarised, so Gatekeeper is quiet. macOS 14+.

**Or build it** — no Zig toolchain and no Ghostty checkout required:

```sh
git clone https://github.com/riclib/zmxterm && cd zmxterm
swift build
swift run zmxterm
```

## Dependencies

**Required — one:**

```sh
brew install neurosnap/tap/zmx      # session persistence; everything rests on it
```

**Recommended:**

```sh
brew install zsm                    # the same workspace, as a TUI, from any terminal
```

**Optional, for the reader.** Panes can display a document, and which viewer
runs is chosen by file type. Install the ones you want; **a rule whose viewer is
missing falls through to the next**, so nothing breaks if you install none of
them and everything falls back to `less`:

| for | install | notes |
| --- | --- | --- |
| markdown | [`mdv`](https://github.com/posaune0423/mdv) | renders mermaid diagrams inline; needs `mmdc` or `mmdr` for those |
| markdown | `brew install glow` | the fallback if `mdv` is absent |
| logs | `brew install hl` | follows and formats structured logs live |
| anything | `brew install bat` | syntax highlighting; falls back to `less`, which you already have |

**Optional, elsewhere:**

- **Ghostty** — not required. Its themes and terminfo are bundled, so `theme =`
  resolves without it. Install it if you want the config you already have.
- **An editor** — whatever `$EDITOR` says, else `vim`.
- **Obsidian or Octarine** — only if you want the daily-log panel.

## Using it

**Tabs and panes.** A tab is a group of panes; a pane is a session. Both are
labels, so both are things an agent can create.

| | |
| --- | --- |
| ⌘T | new tab — proposes a name, already selected, so typing replaces it |
| ⌘D | split right |
| ⇧⌘D | split down |
| ⌘B | show/hide the left rail |
| ⌥⌘B | show/hide the right inspector |
| ⇧⌘, | reload the Ghostty config (the same binding Ghostty uses) |

Right-click a pane for the rest: rename, split, mark disposable, **Remove from
Tab** — which takes a pane off screen while leaving what runs in it alone — and
Kill, which is the only thing here that ends a process and the only one that
asks first.

**The rail, on the left**, is every tab and every pane, with each pane's icon
saying what is running in it and its colour saying whether it wants you.

**The inspector, on the right**, has two panels. *Files* is a tree rooted at the
focused pane's working directory, following it as the pane changes directory.
*Today* is your daily note, one card per entry, clicking through to the app that
owns it.

**Getting a file into a pane**, three ways, all of which quote the path so a
name with a space arrives as one argument and nothing is ever executed for you:

- **Drag it from Finder** onto a pane — inserts the path at that pane's prompt.
- **Double-click it in the tree** — the same, relative when it is under the
  pane's directory.
- **Open in Reader / Open in Editor** from the tree's context menu. The reader is
  one pane per tab and the next document replaces the last; the editor is the
  opposite and gets a new pane every time, because replacing a buffer somebody
  is typing into is the worst thing this app could do.

**Dividers** drag to resize, and the sizes are written back as labels — so a
layout you arrange by hand is a layout an agent can read, and vice versa.

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
defaults write land.liberato.zmxterm editorCommand "hx"        # unset: $EDITOR, then vim
defaults write land.liberato.zmxterm flagFailedTasks -bool false
defaults write land.liberato.zmxterm reapEphemeralOnLaunch -bool true
```

The Today panel is four more, and it appears only once all four are there —
three, for a template that names no vault:

```sh
defaults write land.liberato.zmxterm dailyAdapter octarine       # or obsidian, or a URL template
defaults write land.liberato.zmxterm dailyVault Solid            # the name the app knows it by
defaults write land.liberato.zmxterm dailyRoot ~/Library/Mobile\ Documents/iCloud~com~octarine~notes/Documents/Solid
defaults write land.liberato.zmxterm dailyTemplate -string 'Daily/{yyyy-MM-dd}.md'
```

**`-string` is not optional on that last one.** `defaults` reads a bare value
containing braces as an old-style plist and refuses it — `Could not parse:
Daily/{yyyy-MM-dd}.md` — which looks like the app rejecting the template rather
than the shell tool never having accepted it. Anything in braces is a
`DateFormatter` pattern, in `en_US_POSIX` and the local time zone, so
`{yyyy}/{MM}/{dd}.md` works as well as the one above.

Setting some but not all of them leaves the panel hidden, deliberately and
silently — a half-configured panel would be a list of lines that do nothing when
clicked. `swift run zmxterm --selftest` prints which piece is missing, and that
is what the line is there for.

A `swift run` build is not the bundle, so its defaults domain is `zmxterm`
rather than the bundle id.

The config is loaded with an empty `TerminalTheme`. The controller otherwise
overlays a light/dark palette *after* the file, which would silently override a
`theme =` line. The trade is that panes follow the config rather than the system
appearance, which is what someone who wrote a theme into their config already
asked for.

## How it works

The rest of this is the reasoning, kept because every part of it cost
something to learn.

### The model

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

### Attention

Wiring is under [Running several Claudes](#running-several-claudes); this is why
it is shaped that way.

Which pane needs you is reported by the pane, never inferred from its screen.
Reading a screen to guess whether a program is finished is a heuristic that gets
worse as the program gets more talkative; a label the program writes about
itself is a fact. `bin/zmx-state` writes it into whatever session it is run
inside, and is a silent no-op outside one, so the same line is safe in a global
hook that also fires on machines with no zmx at all.

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

### The reader

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

### The editor

**Open in Editor** is next to Open in Reader on the same file, and is its
opposite in the way that matters: it opens **a new pane every time**. The reader
is a stable panel whose point is that the next document replaces the last; an
editor holds a buffer somebody is typing into, and replacing that would be the
worst thing this app could do. So there is no `editor=1` label, nothing is
looked up, and nothing is reused — Open in Editor splits a pane exactly as the
Split menu item does and then forgets about it.

Nothing ever sends a quit key to it, either. The reader has a careful
stop-then-signal dance because it means to reuse the pane; there is nothing here
to clear, and typing a quit key at somebody's vim is precisely the accident this
design avoids. Closing the editor is the user's business.

The editor is **the login shell's `$EDITOR`, falling back to `vim`**, and asking
the shell is deliberate: someone who has set `EDITOR` has already answered this
question, and a second place to answer it is a second place for the two to
disagree. It is read from the same one interactive-shell call that resolves the
PATH the viewers are checked against, so it costs nothing. `$EDITOR` is taken as
a command line rather than a binary, so `code -w` keeps its argument, and the
command runs in the pane's shell — a wrapper script or a shell function works if
the shell resolves it.

```sh
defaults write land.liberato.zmxterm editorCommand "hx {path} +10"   # overrides $EDITOR
```

Same shape as `readerCommand`: `{path}` where the file goes, or nothing and it
is appended. The path is absolute and quoted with the same rule the tree inserts
paths with, so a filename with a space in it cannot mean one thing in one menu
item and something else in the other.

The new pane is `ephemeral=1` like any split, and the reaper reads that
correctly without being told: its "something other than a login shell is
running" veto protects an editor with unsaved work in it, and once you quit the
editor the pane is an ordinary idle shell, which is exactly when it should be
reapable.

### Today

A second inspector panel: every **top-level** bullet of today's daily note,
newest first, one card each showing the whole line wrapped. Clicking a card
opens the note in whichever PKM app owns it.

The cards are the app's own chrome — `Theme.groupCard` at `Theme.cornerRadius`,
spaced by `Theme.gap` — which is what a tab group in the rail and a pane in the
canvas are already made of, so the panel reads as the same application rather
than a widget dropped into it. Under the pointer a card takes an accent border
and the cursor becomes the pointing hand: with the full text on screen there is
no tooltip left to say a card is clickable, so the hover state says it instead.

It was twelve truncated lines to begin with, both halves of that a concession to
a panel that might have lived under the usage meters. It has a column, so the
list is as long as the day was and scrolls.

**It is invisible unless you configure it**, and that is the feature working
rather than a caveat — most people have no daily note and should see no panel,
no placeholder and no explanation. Unconfigured, the inspector has one panel and
no picker, exactly as before.

Top-level only, because the sub-bullets under each are the evidence and the top
line is the claim. Newest first, because a daily note is appended to and the
interesting end is the bottom. Fenced blocks are skipped, so a pasted shell
transcript cannot contribute lines it never meant as bullets. Inline markdown is
rendered where it is free — `AttributedString` handles bold and links and leaves
`[[wikilinks]]` alone — and the floor under it is plain text: a real line in the
note this was built against has its emphasis markers a word out of place, and
markdown bolds the wrong half rather than failing, which is fine. What is not
fine is a line that vanishes, and none does.

Clicking opens the *note*, not the line. Neither app's scheme addresses a block,
and a link claiming to would land somewhere else.

A morning with no note yet is the normal state, not an error, and says so
quietly.

**Adding a third app is a line, not a fork.** Almost none of the work is
app-specific: finding the file is a vault root plus a path template with a date
in it, and parsing is markdown. Only the URL differs, so an adapter is a name
and a template with two holes in it:

```swift
Adapter(id: "obsidian", name: "Obsidian",
        template: "obsidian://open?vault={vault}&file={path}")
Adapter(id: "octarine", name: "Octarine",
        template: "octarine://open?path={path}&workspace={vault}")
```

Both holes are percent-encoded against the unreserved set, so a `/` inside a
parameter value becomes `%2F` and a note called `Q&A.md` stays one parameter.
An app with no adapter still works today: write its URL template into
`dailyAdapter` instead of a name, and anything containing `{path}` is read as
one.

Three things this gets right that are easy to get wrong. The path is re-resolved
rather than watched, so **midnight moves it** to tomorrow's note by itself. The
file is watched as well, because entries land as work does. And an **iCloud file
that has been evicted** leaves a hidden `.name.md.icloud` placeholder where it
was, which `fileExists` answers "no" to exactly as it does for a note nobody
wrote — so that case asks for the download and says so, rather than reporting an
empty day that is only an absent one.

### Dropping files from Finder

Drop files or folders on a pane and their paths are inserted at its prompt, the
way Terminal.app and Ghostty do. Several files insert several paths, space
separated, in the order they were selected — nothing sorts them, because `cp a
b` is not `cp b a`.

It is the same `FileTree.insertion` the tree's double-click uses, so a file
arrives as the same string whichever gesture sent it: relative when it is under
the pane's directory, absolute otherwise, and shell-quoted. **Nothing is
executed** — there is no trailing newline, the path lands at the cursor, and
what to do with it is the human's decision.

The drop goes to the pane under the pointer rather than to the window, and that
pane then takes the keyboard. Targeting is by construction rather than by
aiming: each pane has its own drop handler closed over its own session, so a
drop cannot reach whichever pane happened to be focused.

**It does not cost text selection or divider drags**, which was the risk worth
checking rather than assuming — the same mouse-down that starts a selection in
the terminal is the one a drop target could have swallowed. A drop registration
is a different event path: AppKit resolves a dragging destination by walking up
from the view under the pointer to one that accepts the type, and libghostty's
surface registers no dragged types at all, so the drag finds the pane and
ordinary clicks never do. Measured, not reasoned: with the registration and
without it, a hit-test of every point across the window returns the same view,
and the divider gesture reaches its commit identically.

A filename may legally contain a newline, which would otherwise be a command
that runs. Quoting is what defuses it rather than bracketed paste: the newline
lands inside the single quotes and the shell waits for the close. Bracketed
paste is deliberately **not** used, because it cannot be used honestly here —
the app writes to zmx as `.input` and never through libghostty's `sendText`,
which is the thing that knows whether the remote shell enabled mode 2004.
Wrapping unconditionally would put literal `ESC[200~` on the prompt of every
shell that has it off. Doing it properly means tracking the mode out of the
byte stream we already receive; quoting makes that a refinement rather than a
fix.

### The inspector

⌥⌘B collapses the right sidebar the way ⌘B collapses the left, and to a strip of
icons for the same reason. The container is an enum of panels and a `switch`, so
the next one is a case rather than a rewrite — which is how the second arrived.
Files is about whatever the focused pane is looking at; Today is about the day
and follows nothing, which the container turned out not to mind. Which panels
exist is decided in one place, because Today is offered only where it has been
configured and a panel missing from the rail must not stay reachable through a
stored preference.

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

### The rail

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

### Files

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
Daily.swift         PKM adapters, today's note path, top-level bullets; the watcher
DailyPanel.swift    twelve lines, newest first, each one a click into the app
Reader.swift        the `reader=1` pane: the viewer rules, what gets typed, when it is stopped
Editor.swift        Open in Editor: which editor, and why it is never the reader's pane
ReapPolicy.swift    which scratch panes are safe to destroy; the launch pass
SelfTest.swift      headless tree and drag tests
bin/zmx-state       the attention hook
```

### Layout and dragging

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

### Reaping

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

### Quota

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

### Protocol notes

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

### Building

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

### Packaging

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

Pre-1.0. The model is settled; the surface is still moving.

```sh
swift run zmxterm --selftest     # 300+ headless checks, no window and no daemon
```

Terminal emulation, PTY and Metal rendering come from
[Ghostty](https://ghostty.org) via
[libghostty-spm](https://github.com/Lakr233/libghostty-spm). Session persistence
is [zmx](https://github.com/neurosnap/zmx). All three are MIT, as is this. Agent
icons and their licences are in `Sources/zmxterm/Resources/icons/CREDITS.md`.

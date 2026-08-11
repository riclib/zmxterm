---
name: zmxterm
description: Use when you are running inside a zmx session (ZMX_SESSION is set) and need to arrange, create, name, or report on terminal panes — laying out a wall of agents, splitting a pane, marking yourself as waiting for the human, or cleaning up scratch sessions. Triggers include "open a pane", "split right", "split down", "put the devs on screen", "set up a workspace", "show me the agents", "tell me when you need me", "close that pane", and any mention of zmxterm, zmx or zsm.
---

# Driving the zmxterm workspace

You arrange panes by writing labels onto zmx sessions. There is no app API and
nothing to ask permission from: sessions are the truth, labels say where they
go, and zmxterm renders whatever it finds. `zsm` in any terminal shows the same
thing, so your edits are visible whether or not anyone has the GUI open — write
labels freely even when you don't know if zmxterm is running.

## Know which pane you are

zmx exports `ZMX_SESSION` into every session's shell. That is your handle:

```bash
echo "$ZMX_SESSION"          # e.g. spike.dev-1
```

If it's empty you are not inside a zmx session, and none of the rest applies —
say so rather than guessing at a name.

`ZMXTERM=1` is set only in sessions zmxterm itself created. It answers "did the
app make me", never "am I on screen", so don't branch on it to decide whether to
write labels. Write them regardless.

## Tell the human you need them

This is the most valuable thing you can do here, and it replaces them having to
watch your output:

```bash
zmx set "$ZMX_SESSION" state=waiting    # I've stopped and want a human
zmx set "$ZMX_SESSION" state=failed     # something went wrong
zmx set "$ZMX_SESSION" state=           # resting (empty value removes it)
```

Your pane's icon turns from grey to full colour, and in the collapsed rail that
is the whole signal — a column of dim glyphs with one lit. Focusing your pane
clears it, so don't re-set `waiting` on a loop; set it once when you stop.

## The label vocabulary

| label | meaning |
| --- | --- |
| `tab` | which tab the pane belongs to. Defaults to the name before the first dot, so `spike.dev-1` groups under `spike` for free. Set it explicitly to gather panes from different agents onto one wall. |
| `pos` | slot in the tab's split tree, e.g. `v0.h1.v2`. Each segment is the parent's axis (`h` = side by side, `v` = stacked) plus a child index. |
| `size` | share of the **whole tab**, 0–1, not of the parent split. Omit and the pane splits whatever is left over. |
| `state` | `waiting`, `failed`, or unset. |
| `title` | what the pane calls itself. zmx cannot rename a session, so this is the only way to change what is displayed. |
| `ephemeral` | `1` marks a scratch pane that gets reaped rather than restored. Naming something is what promotes it. |

Values accept only `[A-Za-z0-9._-]` — no spaces, no slashes, no JSON. Fold
anything a human typed: `my project` becomes `my-project`.

## Read the current layout before changing it

```bash
zmx list                          # every session, with its labels inline
zmx get spike.dev-1               # one session's labels
zmx list | grep 'tab=spike\b'     # just one tab
```

`zmx list --where k=v` is advertised in `zmx --help` but is not implemented —
the flag is accepted and ignored, so it returns everything and looks like it
worked. Filter with `grep`.

Never assume a slot is free. Read `pos` across the tab, then claim the next
index.

## Create a pane

```bash
cd /path/to/worktree
zmx attach spike.logs < /dev/null > /dev/null 2>&1
zmx set spike.logs tab=spike pos=h1 size=0.5
```

`zmx attach` with stdin closed creates the session running a login `$SHELL` and
detaches immediately, leaving it running with nobody watching. The session
inherits the working directory you run it from.

Do **not** use `zmx run` to make a shell. That is task mode: it echoes the
command, appends a `ZMX_TASK_COMPLETED:$?` marker and runs under bash, so the
pane opens showing its own plumbing. `zmx run` is for firing a command into an
existing session and waiting on it.

## Split an existing pane

Splitting is two decisions: which axis, and whether that axis already exists.

**Same axis as the parent — insert a sibling.** A pane at `h1` splitting right
means the newcomer takes `h2` and everything at `h2` or beyond shifts up one.
This keeps a row flat (`h[a b c]`) instead of nesting it.

**Different axis — deepen.** A pane at `h1` splitting *down* becomes `h1.v0`,
and the newcomer takes `h1.v1`. Only those two rows change; every other pane
keeps its position.

Halve the original's `size` and give the other half to the newcomer.

## Lay out a wall of agents

The common request — "put the two devs and the reviewer on screen with the
orchestrator". Names carry identity, labels carry placement:

```bash
zmx set spike.orc   tab=wall pos=v0.h0    size=0.30
zmx set spike.dev-1 tab=wall pos=v0.h1.v0 size=0.15
zmx set spike.dev-2 tab=wall pos=v0.h1.v1 size=0.15
zmx set spike.rev-1 tab=wall pos=v0.h1.v2 size=0.15
zmx set spike.sh-1  tab=wall pos=v1.h0    size=0.125
zmx set spike.sh-2  tab=wall pos=v1.h1    size=0.125
```

That reads as: the tab splits vertically into a top region and a bottom strip;
the top splits horizontally into the orchestrator and a stacked column of three;
the bottom holds two shells side by side. Sizes sum to 1 across the whole tab.

## Name things

```bash
zmx set spike.logs title=build-watch          # what one pane is called
for s in $(zmx list | grep 'tab=wall\b' | grep -o 'name=[^ 	]*' | cut -d= -f2); do
    zmx set "$s" tab=spike-team                # rename the tab itself
done
```

A pane's *name* is its socket path and can never change; `title` is the display.
A *tab's* name is just the `tab` label, so rewriting it across the tab's panes
is a real rename.

## Clean up after yourself

```bash
zmx set spike.logs ephemeral=1     # scratch: reap it, don't restore it
zmx kill spike.logs --force        # actually stop what's running in it
```

Killing ends the process. Removing a pane from view without killing it is
clearing its placement instead:

```bash
zmx set spike.logs pos= tab=
```

Only kill sessions you created or were told to. A pane you didn't make may hold
someone's twenty minutes of work, and closing a pane in the GUI deliberately
does not kill anything — don't be the thing that does.

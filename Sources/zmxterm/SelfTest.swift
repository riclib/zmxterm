import AppKit
import Foundation

/// Headless checks for the parts that don't need a window: position parsing and
/// tree reconstruction. `swift run zmxterm --selftest`
///
/// The tree is the load-bearing claim of the whole design — that a layout can
/// live in per-session labels and be rebuilt from nothing else — so it's worth
/// being able to verify without eyes on a screen.
enum SelfTest {
    static func run() -> Int32 {
        var failures = 0

        func expect(_ label: String, _ actual: String, _ expected: String) {
            let ok = actual == expected
            if !ok { failures += 1 }
            print("\(ok ? "ok  " : "FAIL") \(label)")
            if !ok {
                print("       expected: \(expected)")
                print("       actual:   \(actual)")
            }
        }

        // The `team` layout: orc on the left, the band stacked to its right,
        // two plain shells across the bottom.
        let team = shape([
            ("spike.orc", "v0.h0", nil),
            ("spike.dev-1", "v0.h1.v0", nil),
            ("spike.dev-2", "v0.h1.v1", nil),
            ("spike.rev-1", "v0.h1.v2", nil),
            ("spike.sh-1", "v1.h0", nil),
            ("spike.sh-2", "v1.h1", nil),
        ])
        expect(
            "team layout",
            team,
            "v[h[spike.orc v[spike.dev-1 spike.dev-2 spike.rev-1]] h[spike.sh-1 spike.sh-2]]"
        )

        expect("single pane, no position", shape([("solo", nil, nil)]), "solo")

        expect(
            "unpositioned panes sit side by side",
            shape([("a", nil, nil), ("b", nil, nil)]),
            "h[a b]"
        )

        // A split with one child is just the child: closing a sibling shouldn't
        // require rewriting the survivor's label before it renders.
        expect("lone child collapses", shape([("only", "h1.v3", nil)]), "only")

        // Out-of-order and sparse indices still sort by slot, not by name.
        expect(
            "sparse indices keep order",
            shape([("second", "h5", nil), ("first", "h2", nil)]),
            "h[first second]"
        )

        expect("fractions normalise", fractions([
            ("a", "h0", 0.25), ("b", "h1", 0.75),
        ]), "0.25, 0.75")

        expect("absent fractions split the remainder", fractions([
            ("a", "h0", 0.5), ("b", "h1", nil), ("c", "h2", nil),
        ]), "0.50, 0.25, 0.25")

        expect("no fractions at all means equal", fractions([
            ("a", "h0", nil), ("b", "h1", nil), ("c", "h2", nil),
        ]), "0.33, 0.33, 0.33")

        // Drag math. The whole point is that it depends only on fixed
        // quantities, so it can be checked without a pointer.
        let divider = PaneLayout.Divider(
            id: "#0", axis: .horizontal, rect: .zero, splitID: "", boundary: 0,
            fractions: [0.5, 0.5], extent: 1000, regionOrigin: 0, gap: 8
        )
        expect(
            "drag to an absolute position",
            describe(PaneLayout.fractions(draggingTo: 300, divider: divider, base: [0.5, 0.5])),
            "0.296, 0.704"
        )
        expect(
            "same position twice is idempotent",
            describe(PaneLayout.fractions(draggingTo: 300, divider: divider, base: [0.5, 0.5])),
            describe(PaneLayout.fractions(draggingTo: 300, divider: divider, base: [0.5, 0.5]))
        )
        expect(
            "floor refuses the drag",
            describe(PaneLayout.fractions(draggingTo: 20, divider: divider, base: [0.5, 0.5])),
            "<none>"
        )

        let nested = PaneLayout.Divider(
            id: "1#1", axis: .vertical, rect: .zero, splitID: "1", boundary: 1,
            fractions: [0.4, 0.3, 0.3], extent: 900, regionOrigin: 200, gap: 8
        )
        // Children before the boundary keep their share; only the pair moves.
        expect(
            "nested split, offset region, middle boundary",
            describe(PaneLayout.fractions(draggingTo: 800, divider: nested, base: [0.4, 0.3, 0.3])),
            "0.400, 0.253, 0.347"
        )

        // Icons: both that the rule picks the right asset and that the asset
        // actually resolves out of the resource bundle at runtime.
        expect("claude session picks the Claude mark", iconAsset(command: "claude --model opus"), "claudecode")
        expect("codex session picks the Codex mark", iconAsset(command: "codex"), "codex")
        expect("grok session picks the Grok mark", iconAsset(command: "grok chat"), "grok")
        expect("a plain shell falls back", iconAsset(command: "/bin/zsh -l"), "terminal")
        expect("matching is case-insensitive", iconAsset(command: "Claude Code"), "claudecode")
        expect("a binary called solid", iconAsset(command: "solid serve"), "solid")
        expect("a pane working in a solid folder", iconAsset(command: "/bin/zsh", dir: "/Users/riclib/envs/solidmon/v4"), "solid")
        // An agent in that folder is still an agent: what it runs outranks where.
        expect("an agent in a solid folder stays an agent",
               iconAsset(command: "claude --model opus", dir: "/Users/riclib/envs/solidmon/v4"), "claudecode")
        expect("an unrelated folder doesn't claim it", iconAsset(command: "/bin/zsh", dir: "/Users/riclib/envs/other"), "terminal")

        for asset in ["claudecode", "codex", "grok", "solid", "terminal"] {
            expect("asset \(asset) loads", PaneIcon.image(named: asset) != nil ? "loaded" : "missing", "loaded")
        }

        // Titles: tab owns what's before the dot, pane owns what's after.
        let wall = [session("spike.orc"), session("spike.dev-1"), session("spike.dev-2")]
        expect("a pane shows its part", PaneLabel.display(wall[1], among: wall), "dev-1")
        let agents = [session("spike-dev-1"), session("spike-dev-2")]
        expect("no dot means the whole name", PaneLabel.display(agents[0], among: agents), "spike-dev-1")
        let clash = [session("dev-1.shell"), session("dev-2.shell"), session("dev-1.claude")]
        expect("a repeated part falls back to the full name",
               PaneLabel.display(clash[0], among: clash), "dev-1.shell")
        expect("a unique part still shortens", PaneLabel.display(clash[2], among: clash), "claude")

        // Splitting. The interesting property is that a matching axis inserts
        // a sibling rather than nesting, so a third pane keeps the row flat.
        let row = [positioned("t.a", "h0", 0.5), positioned("t.b", "h1", 0.5)]
        expect("splitting right inserts a sibling",
               describe(PaneOps.split(panes: row, focused: "t.a", axis: .horizontal, newSession: "t.ford", tab: "t")),
               "t.b:h2 | t.a:size=0.250 | t.ford:h1 size=0.250")
        expect("the flat row survives the split",
               shapeOf(apply(PaneOps.split(panes: row, focused: "t.a", axis: .horizontal, newSession: "t.ford", tab: "t"), to: row)),
               "h[t.a t.ford t.b]")

        expect("splitting down deepens instead",
               describe(PaneOps.split(panes: row, focused: "t.a", axis: .vertical, newSession: "t.ford", tab: "t")),
               "t.a:h0.v0 size=0.250 | t.ford:h0.v1 size=0.250")
        expect("the deepened tree nests only that pane",
               shapeOf(apply(PaneOps.split(panes: row, focused: "t.a", axis: .vertical, newSession: "t.ford", tab: "t"), to: row)),
               "h[v[t.a t.ford] t.b]")

        let alone = [positioned("t.a", nil, nil)]
        expect("a lone pane splits from nothing",
               describe(PaneOps.split(panes: alone, focused: "t.a", axis: .horizontal, newSession: "t.ford", tab: "t")),
               "t.a:h0 size=0.500 | t.ford:h1 size=0.500")

        // Tabs get a name worth saying out loud; panes get a number.
        expect("first free tab name", SessionNames.nextTab(avoiding: []), "arthur")
        expect("tabs skip what's taken", SessionNames.nextTab(avoiding: ["arthur", "ford"]), "zaphod")
        expect("panes are numbered in their tab", SessionNames.nextPane(in: "zaphod", avoiding: []), "zaphod.shell-1")
        expect("pane numbering skips gaps in use",
               SessionNames.nextPane(in: "zaphod", avoiding: ["zaphod.shell-1", "zaphod.shell-2"]), "zaphod.shell-3")
        expect("pane numbering is per tab",
               SessionNames.nextPane(in: "ford", avoiding: ["zaphod.shell-1"]), "ford.shell-1")

        // Renaming has to survive the label charset, which allows only
        // [A-Za-z0-9._-]. Anything typed gets folded rather than rejected.
        expect("spaces become dashes", Zmx.slug("my project"), "my-project")
        expect("punctuation is dropped", Zmx.slug("orc: the wall!"), "orc-the-wall")
        expect("dots and dashes survive", Zmx.slug("v4.2-beta"), "v4.2-beta")
        expect("surrounding space is trimmed", Zmx.slug("  ford  "), "ford")
        expect("an all-punctuation name empties out", Zmx.slug("!!!"), "")

        // A title, when set, outranks the part derived from the name.
        var titled = session("t.shell-1")
        titled = ZmxSession(name: titled.name, pid: "1", clients: 1, startDir: "/tmp",
                            command: "zsh", labels: ["title": "logs"])
        expect("a title wins over the name", PaneLabel.display(titled, among: [titled]), "logs")

        // Taking a pane off a tab. Every session belongs to *some* tab, so what
        // a test can settle is where the pane lands — not whether it vanishes,
        // because nothing here can make it vanish.
        let gathered = labelled("spike.dev-1", ["tab": "wall", "pos": "v0.h1", "size": "0.25"])
        expect("a gathered pane can leave its tab", flag(gathered.canLeaveTab), "yes")
        expect("and falls back to the name before the dot", unplaced(gathered).tab, "spike")
        expect("leaving drops the share as well as the slot",
               describe(unplaced(gathered).sizeFraction.map { [$0] }), "<none>")

        // A pane already under its own name is still removable if it has been
        // placed — clearing `pos` is what pulls it out of a split.
        expect("a placed pane can leave its own tab", flag(labelled("m3.sh-1", ["tab": "m3", "pos": "v1.h0"]).canLeaveTab), "yes")
        expect("an unplaced lone pane has nowhere to go", flag(labelled("zaphod", [:]).canLeaveTab), "no")
        expect("nor does an unplaced pane sitting in its default tab",
               flag(labelled("m3.sh-1", [:]).canLeaveTab), "no")

        // Renaming a tab onto a name in use is a merge, and a merge is not
        // reversible, so the interesting property is that the two cases are
        // told apart before anything is written.
        let twoTabs = [
            labelled("alpha.a", ["tab": "alpha"]), labelled("alpha.b", ["tab": "alpha"]),
            labelled("beta.a", ["tab": "beta"]),
        ]
        expect("a free name is a plain rename",
               rename(PaneOps.renameTab("alpha", to: "gamma", among: twoTabs)), "rename gamma")
        expect("an occupied name is a merge",
               rename(PaneOps.renameTab("alpha", to: "beta", among: twoTabs)), "merge beta")
        expect("renaming to itself does nothing",
               rename(PaneOps.renameTab("alpha", to: "alpha", among: twoTabs)), "unchanged")
        expect("a name that folds to nothing does nothing",
               rename(PaneOps.renameTab("alpha", to: "!!!", among: twoTabs)), "unchanged")
        // Typed input is folded before the collision test, or "beta!" would
        // look free and then land on `beta` anyway. Note spaces become dashes
        // rather than vanishing, so "bet a" is genuinely a different name.
        expect("punctuation folds before the collision test",
               rename(PaneOps.renameTab("alpha", to: "beta!", among: twoTabs)), "merge beta")
        expect("but a space is a dash, and that is a free name",
               rename(PaneOps.renameTab("alpha", to: "bet a", among: twoTabs)), "rename bet-a")
        // Case is not folded, because zmx's labels are case-sensitive and this
        // check has to agree with what `zsm` would show. `Beta` really is a
        // different tab from `beta`, however unhelpful that is to look at.
        expect("case is not folded, so it is not a collision",
               rename(PaneOps.renameTab("alpha", to: " Beta ", among: twoTabs)), "rename Beta")

        // A tab can be occupied by a session that never asked for it: `tab`
        // falls back to the name before the dot, so `zaphod` holds that name
        // with no label at all.
        let unlabelled = [labelled("alpha.a", ["tab": "alpha"]), labelled("zaphod", [:])]
        expect("an unlabelled session still occupies its name",
               rename(PaneOps.renameTab("alpha", to: "zaphod", among: unlabelled)), "merge zaphod")
        expect("and renaming it onto a labelled tab is a merge too",
               rename(PaneOps.renameTab("zaphod", to: "alpha", among: unlabelled)), "merge alpha")

        // New Tab now asks before it creates, which turns two guesses into two
        // decisions — is this name free, and did the user actually name it —
        // and both are settled here rather than in a dialog nobody can test.
        //
        // The name space a new tab has to be free of is wider than the one a
        // rename has to be free of, because creating a tab creates a session
        // and a session's name is its socket path.
        let liveNames = [
            labelled("alpha.a", ["tab": "alpha"]),
            labelled("zaphod", ["tab": "alpha"]),
            labelled("beta.a", ["tab": "beta"]),
        ]
        expect("tab names in use include the sessions themselves",
               PaneOps.occupiedTabNames(among: liveNames).sorted().joined(separator: " "),
               "alpha alpha.a beta beta.a zaphod")

        // Accepting the proposal is not naming anything, so the tab stays
        // disposable and the reaper may eventually take it.
        expect("the proposal accepted stays disposable",
               newTab(PaneOps.newTab(typed: "marvin", proposed: "marvin", among: liveNames)),
               "create marvin ephemeral")
        expect("a name of your own is a name, so it is kept",
               newTab(PaneOps.newTab(typed: "logs", proposed: "marvin", among: liveNames)),
               "create logs kept")
        // Blank and punctuation-only are the same case: there is no nameless
        // session to create, so they read as taking the offer rather than as
        // an error.
        expect("an empty field takes the offer",
               newTab(PaneOps.newTab(typed: "", proposed: "marvin", among: liveNames)),
               "create marvin ephemeral")
        expect("so does a field of spaces",
               newTab(PaneOps.newTab(typed: "   ", proposed: "marvin", among: liveNames)),
               "create marvin ephemeral")
        expect("and one that folds away entirely",
               newTab(PaneOps.newTab(typed: "!!!", proposed: "marvin", among: liveNames)),
               "create marvin ephemeral")
        // Folding happens before the comparison as well as before the
        // collision test, so decorating the proposal does not promote it.
        expect("the proposal with punctuation is still the proposal",
               newTab(PaneOps.newTab(typed: " marvin! ", proposed: "marvin", among: liveNames)),
               "create marvin ephemeral")
        expect("typed input is folded on the way to becoming a name",
               newTab(PaneOps.newTab(typed: "my project", proposed: "marvin", among: liveNames)),
               "create my-project kept")

        // Refusal, which is the case that would otherwise attach to a live
        // session instead of creating anything.
        expect("an existing tab name is refused",
               newTab(PaneOps.newTab(typed: "beta", proposed: "marvin", among: liveNames)),
               "taken beta")
        expect("so is a session name that holds no tab of its own",
               newTab(PaneOps.newTab(typed: "zaphod", proposed: "marvin", among: liveNames)),
               "taken zaphod")
        expect("a dotted pane name is a socket path too",
               newTab(PaneOps.newTab(typed: "alpha.a", proposed: "marvin", among: liveNames)),
               "taken alpha.a")
        expect("punctuation folds before the collision test",
               newTab(PaneOps.newTab(typed: "beta!", proposed: "marvin", among: liveNames)),
               "taken beta")
        // Case is not folded here either, for the same reason it is not folded
        // in a rename: zmx's names and labels are case-sensitive, so `Beta` is
        // genuinely a free socket path.
        expect("case is not folded, so it is not a collision",
               newTab(PaneOps.newTab(typed: "Beta", proposed: "marvin", among: liveNames)),
               "create Beta kept")

        // The proposal is what the dialog opens with, so it has to be free of
        // the same wider name space — otherwise accepting the default would be
        // the one gesture that cannot fail and does.
        expect("the proposal avoids sessions as well as tabs",
               SessionNames.nextTab(avoiding: PaneOps.occupiedTabNames(among: [
                   labelled("arthur", ["tab": "wall"]), labelled("ford", ["tab": "wall"]),
               ])),
               "zaphod")
        expect("and an accepted proposal therefore never collides",
               newTab(PaneOps.newTab(typed: "zaphod", proposed: "zaphod", among: [
                   labelled("arthur", ["tab": "wall"]), labelled("ford", ["tab": "wall"]),
               ])),
               "create zaphod ephemeral")

        // Shell integration, where the failure mode is a shell that does not
        // start, so the reentrancy case matters more than the happy one.
        let res = "/R"
        expect("zsh gets ZDOTDIR",
               env(ShellIntegration.environment(shell: "/bin/zsh", resources: res, inherited: [:])),
               "ZDOTDIR=/R/shell-integration/zsh")
        expect("an existing ZDOTDIR is handed over to be restored",
               env(ShellIntegration.environment(shell: "/bin/zsh", resources: res, inherited: ["ZDOTDIR": "/home/me/zsh"])),
               "GHOSTTY_ZSH_ZDOTDIR=/home/me/zsh, ZDOTDIR=/R/shell-integration/zsh")
        // The one that breaks a shell: injecting twice would make the restore
        // point back at Ghostty's own .zshenv and the user's .zshrc would never
        // run.
        expect("injecting onto an injected environment does nothing",
               env(ShellIntegration.environment(shell: "/bin/zsh", resources: res,
                                                inherited: ["ZDOTDIR": "/R/shell-integration/zsh"])),
               "<none>")
        expect("an empty ZDOTDIR is not something to restore",
               env(ShellIntegration.environment(shell: "/bin/zsh", resources: res, inherited: ["ZDOTDIR": ""])),
               "ZDOTDIR=/R/shell-integration/zsh")

        expect("fish prepends to the data path, keeping the XDG defaults",
               env(ShellIntegration.environment(shell: "/opt/fish", resources: res, inherited: [:])),
               "XDG_DATA_DIRS=/R/shell-integration/fish:/usr/local/share:/usr/share")
        expect("an existing data path is preserved, not replaced",
               env(ShellIntegration.environment(shell: "/opt/fish", resources: res, inherited: ["XDG_DATA_DIRS": "/a:/b"])),
               "XDG_DATA_DIRS=/R/shell-integration/fish:/a:/b")
        expect("already first means nothing to do",
               env(ShellIntegration.environment(shell: "/opt/fish", resources: res,
                                                inherited: ["XDG_DATA_DIRS": "/R/shell-integration/fish:/a"])),
               "<none>")
        expect("already present but not first is moved, not duplicated",
               env(ShellIntegration.environment(shell: "/opt/fish", resources: res,
                                                inherited: ["XDG_DATA_DIRS": "/a:/R/shell-integration/fish"])),
               "XDG_DATA_DIRS=/R/shell-integration/fish:/a")
        expect("nushell uses its own directory",
               env(ShellIntegration.environment(shell: "/opt/nu", resources: res, inherited: [:])),
               "XDG_DATA_DIRS=/R/shell-integration/nushell:/usr/local/share:/usr/share")

        // bash needs `--posix` in argv, which `zmx attach` gives no way to
        // supply, so setting the variables would only make it look done.
        expect("bash is left alone",
               env(ShellIntegration.environment(shell: "/bin/bash", resources: res, inherited: [:])), "<none>")
        expect("an unknown shell is left alone",
               env(ShellIntegration.environment(shell: "/bin/tcsh", resources: res, inherited: [:])), "<none>")

        expect("SHELL wins when it is set",
               ShellIntegration.loginShell(inherited: ["SHELL": "/opt/fish"]), "/opt/fish")
        // A Dock launch inherits no SHELL; falling through to the password
        // database is what keeps this agreeing with the shell zmx will spawn.
        expect("and the password database answers when it is not",
               ShellIntegration.loginShell(inherited: [:]).isEmpty ? "empty" : "found", "found")

        // What the app hands `zmx attach`. The one removal is the whole of
        // issue #16: with `ZMX_SESSION` riding along, the client switches the
        // caller's session instead of creating, so Split and ⌘T did nothing at
        // all whenever zmxterm was launched from inside a pane. A test rather
        // than a comment because the line looks like tidy-up and is not.
        let inherited = [
            "ZMX_SESSION": "ford",
            "ZMX_SESSION_PREFIX": "team-",
            "ZMX_SOCKET_DIR": "/tmp/zmx-501",
            "ZMX_BIN": "/opt/homebrew/bin/zmx",
            "ZMX_DIR": "/tmp/zmx-501",
            "SHELL": "/bin/zsh",
        ]
        let handed = Zmx.clientEnvironment(inheriting: inherited)
        expect("the parent's session name never reaches zmx attach",
               handed["ZMX_SESSION"] ?? "<removed>", "<removed>")
        // Deliberately not stripped, each for its own reason — see the doc
        // comment. `ZMX_SESSION_PREFIX` is the one that looks like it should
        // be: it does change what `attach` creates, but `zmx set` applies it
        // too, so removing it only here would leave every new pane unplaced.
        expect("everything else is passed through",
               env(handed.filter { $0.key != "SHELL" }),
               "ZMX_BIN=/opt/homebrew/bin/zmx, ZMX_DIR=/tmp/zmx-501, "
                   + "ZMX_SESSION_PREFIX=team-, ZMX_SOCKET_DIR=/tmp/zmx-501")
        // An app launched from the Dock inherits no ZMX_SESSION, and removing
        // what was never there must not invent an empty one. zmx 0.7.0 happens
        // to treat `ZMX_SESSION=` as unset — measured — but that is its
        // business, and relying on it would make this fix depend on a detail
        // nobody documented. Removing the key means never finding out.
        expect("a Dock launch is unchanged",
               env(Zmx.clientEnvironment(inheriting: ["SHELL": "/bin/zsh"])), "SHELL=/bin/zsh")

        // What the created shell is told it is running in. Issue #22: tools
        // gate features on the emulator's *name*, so `mdv` refused interactive
        // mode under `TERM_PROGRAM=zmxterm` and takes it under `ghostty` —
        // measured in a pane, with the kitty graphics it wants confirmed to
        // survive zmx's emulation and reach our surface. The value looks like a
        // lie, so it is pinned here rather than left to read like a typo: what
        // draws the pane is libghostty, which is what `TERM_PROGRAM` names.
        let session = Zmx.sessionEnvironment(
            inheriting: inherited, terminalType: "xterm-ghostty", emulatorVersion: "1.3.2"
        )
        expect("the pane answers to the emulator that draws it",
               session["TERM_PROGRAM"] ?? "<unset>", "ghostty")
        // The name and the version are read as a pair, so the version has to be
        // the emulator's. Pairing `ghostty` with this app's 0.8.0 would claim a
        // real, pre-1.0 Ghostty and reintroduce #22 one gate later: past the
        // name check, refused by the version check, for a capability we have.
        expect("and gives the emulator's version, not its own",
               session["TERM_PROGRAM_VERSION"] ?? "<unset>", "1.3.2")
        // The app's own version still goes with the app's own variable. This is
        // the pair that must not get crossed.
        expect("while the app's version stays on the app's variable",
               session["ZMXTERM_VERSION"] ?? "<unset>", Zmx.appVersion)
        // Asked of libghostty rather than copied from Package.resolved, so a
        // dependency bump cannot leave it stale. Checked by shape, not value —
        // pinning the number here would be the same staleness in a new place.
        expect("the emulator answers with a version a gate can parse",
               Zmx.emulatorVersion.first.map { $0.isNumber ? "numeric" : "not numeric" } ?? "empty",
               "numeric")
        expect("and it is not this app's version wearing the emulator's name",
               Zmx.emulatorVersion == Zmx.appVersion ? "crossed" : "distinct", "distinct")
        // An emulator with nothing to say drops the variable rather than
        // setting it empty: unset is the case every tool already handles.
        expect("no version to give means no claim made",
               Zmx.sessionEnvironment(
                   inheriting: inherited, terminalType: "xterm-ghostty", emulatorVersion: ""
               )["TERM_PROGRAM_VERSION"] ?? "<unset>", "<unset>")
        // The cost of the line above: "which app am I in" now has to be asked a
        // different way, so these two are the answer and must not quietly go.
        expect("and still says which app made it",
               "\(session["ZMXTERM"] ?? "<unset>")/\(session["ZMXTERM_VERSION"] ?? "<unset>")",
               "1/\(Zmx.appVersion)")
        // The identity claim is not allowed to outrun the terminfo entry the
        // machine actually has: `terminalType` probes for `xterm-ghostty` and
        // falls back, and whatever it answers is what `TERM` carries.
        expect("TERM carries whatever the probe resolved",
               Zmx.sessionEnvironment(
                   inheriting: inherited, terminalType: "xterm-256color", emulatorVersion: "1.3.2"
               )["TERM"] ?? "<unset>",
               "xterm-256color")
        // Built on `clientEnvironment`, so the #16 removal above holds here too
        // — this is the function whose output actually reaches `zmx attach`.
        expect("and the parent's session name is still gone",
               session["ZMX_SESSION"] ?? "<removed>", "<removed>")

        // The keybinds the app takes back. ⌘Q reached the terminal, became an
        // action nothing implements, and the Quit item never fired — so the
        // interesting property is that the user's file survives and ours lands
        // after it, where the last binding for a chord wins.
        let userConfig = "theme = Builtin Pastel Dark\nkeybind = shift+enter=text:\\n"
        let assembled = TerminalConfig.configText(userConfig: userConfig, directory: "/cfg")
        expect("the user's config survives untouched",
               assembled.contains("theme = Builtin Pastel Dark") ? "kept" : "lost", "kept")
        expect("their own keybind survives too",
               assembled.contains("keybind = shift+enter=text:\\n") ? "kept" : "lost", "kept")
        expect("and ours land after it",
               assembled.contains("keybind = super+q=unbind") ? "yes" : "no", "yes")
        expect("ours come last, so a later rebind by the user would win",
               assembled.range(of: "keybind = super+q=unbind")!.lowerBound
                   > assembled.range(of: "keybind = shift+enter")!.lowerBound ? "after" : "before", "after")
        // A relative include would resolve against this process's working
        // directory once the file is passed as text rather than as a path.
        expect("a relative include is made absolute",
               TerminalConfig.configText(userConfig: "config-file = themes/mine", directory: "/cfg")
                   .contains("config-file = /cfg/themes/mine") ? "absolute" : "unchanged", "absolute")
        expect("an absolute include is left alone",
               TerminalConfig.configText(userConfig: "config-file = /etc/x", directory: "/cfg")
                   .contains("config-file = /etc/x") ? "kept" : "mangled", "kept")
        expect("no config at all still unbinds",
               { if case let .generated(text) = TerminalConfig.configSource(path: nil) {
                     return text.contains("super+q=unbind") ? "yes" : "no" } ; return "not generated" }(), "yes")

        // The live process tree, since the whole point is that it beats the
        // directory guess. Skipped when nothing is running to look at.
        let live = Zmx.list()
        if live.isEmpty {
            print("skip no live sessions to resolve")
        } else {
            let running = ForegroundProcess.resolve(sessionPIDs: live.map(\.pid))
            print("ok   resolved \(running.count)/\(live.count) sessions:")
            for session in live.sorted(by: { $0.name < $1.name }) {
                let found = running[session.pid] ?? "—"
                let icon = PaneIcon.asset(for: ZmxSession(
                    name: session.name, pid: session.pid, clients: session.clients,
                    startDir: session.startDir, command: found, labels: session.labels
                ))
                print("       \(session.name) → running \(found), icon \(icon)")
            }
        }

        // ── Reaping ────────────────────────────────────────────────────────
        //
        // The policy that deletes things. It is a pure function of a session
        // list, some `ps`-derived facts and a clock, which is the only reason
        // it can be checked at all: nothing below runs a reap, touches a
        // daemon, or needs a session to exist. Every check names the veto it is
        // about, because a reaper that stops keeping something for the reason
        // you thought is worse than one that stops working.

        func fixture(
            _ name: String,
            clients: Int = 0,
            created: Date? = nil,
            labels: [String: String] = [:]
        ) -> ZmxSession {
            ZmxSession(
                name: name, pid: "1", clients: clients, startDir: "/tmp",
                command: "", labels: labels, createdAt: created
            )
        }
        func facts(_ foreground: String? = nil, _ lastActivity: Date? = nil) -> ReapPolicy.Facts {
            ReapPolicy.Facts(foreground: foreground, lastActivity: lastActivity)
        }
        func why(_ pane: ZmxSession, among sessions: [ZmxSession], _ known: ReapPolicy.Facts, _ now: Date) -> String {
            ReapPolicy.verdict(for: pane, among: sessions, facts: known, now: now).reason
        }

        // The regression that matters most: these are the sessions that were
        // actually running on this machine while the policy was written, with
        // their real labels. Three of them carry `ephemeral=1` — two tabs a
        // human has been working in all day and one that had been sitting at
        // zero clients — and not one of them is disposable. If a change to the
        // policy makes this check fail, the change is wrong, whatever it
        // improved elsewhere.
        let observed = Date(timeIntervalSince1970: 1_786_487_904)
        let liveMachine: [ZmxSession] = [
            fixture("arthur", clients: 1, created: Date(timeIntervalSince1970: 1_786_482_693),
                    labels: ["ephemeral": "1", "pos": "h0", "size": "0.500", "tab": "arthur", "title": "orc"]),
            fixture("ford", clients: 1, created: Date(timeIntervalSince1970: 1_786_485_430),
                    labels: ["ephemeral": "1", "pos": "v0", "size": "0.500", "tab": "ford"]),
            fixture("m3.dev-1", clients: 1, created: Date(timeIntervalSince1970: 1_786_486_573),
                    labels: ["pos": "v0.h1.v0", "size": "0.129", "tab": "m3", "title": "dev-1"]),
            fixture("m3.dev-2", clients: 1, created: Date(timeIntervalSince1970: 1_786_486_573),
                    labels: ["pos": "v0.h1.v1", "size": "0.129", "tab": "m3", "title": "dev-2"]),
            fixture("m3.rev-1", clients: 1, created: Date(timeIntervalSince1970: 1_786_486_573),
                    labels: ["pos": "v0.h1.v2", "size": "0.129", "state": "waiting", "tab": "m3", "title": "rev-1"]),
            fixture("m3.sh-1", clients: 1, created: Date(timeIntervalSince1970: 1_786_486_044),
                    labels: ["pos": "v1.h0", "size": "0.125", "tab": "m3", "title": "sh-1"]),
            fixture("m3.sh-2", clients: 1, created: Date(timeIntervalSince1970: 1_786_486_044),
                    labels: ["pos": "v1.h1", "size": "0.125", "tab": "m3", "title": "sh-2"]),
            fixture("trillian", clients: 1, created: Date(timeIntervalSince1970: 1_786_485_818),
                    labels: ["pos": "v0.h0", "size": "0.364", "tab": "m3", "title": "orc"]),
            fixture("zaphod", clients: 0, created: Date(timeIntervalSince1970: 1_786_482_941),
                    labels: ["ephemeral": "1", "tab": "zaphod"]),
        ]
        // Measured the same minute: an agent under `ford`, a bare shell under
        // `zaphod` whose terminal had last moved twenty-two minutes earlier.
        let liveFacts: [String: ReapPolicy.Facts] = [
            "ford": facts("claude", Date(timeIntervalSince1970: 1_786_487_904)),
            "arthur": facts("claude", Date(timeIntervalSince1970: 1_786_487_976)),
            "m3.dev-1": facts("claude", Date(timeIntervalSince1970: 1_786_487_904)),
            "m3.dev-2": facts("claude", Date(timeIntervalSince1970: 1_786_487_904)),
            "m3.rev-1": facts("claude", Date(timeIntervalSince1970: 1_786_487_904)),
            "m3.sh-1": facts(nil, Date(timeIntervalSince1970: 1_786_487_827)),
            "m3.sh-2": facts(nil, Date(timeIntervalSince1970: 1_786_487_827)),
            "trillian": facts("claude", Date(timeIntervalSince1970: 1_786_487_904)),
            "zaphod": facts(nil, Date(timeIntervalSince1970: 1_786_486_644)),
        ]
        expect("the live machine loses nothing",
               ReapPolicy.reapable(from: liveMachine, facts: liveFacts, now: observed).joined(separator: ", "), "")
        // …and mostly not because the clock happened to be kind. Run the same
        // list a month later with nothing touched since, and every session held
        // by a signal that has nothing to do with age is still held. The single
        // exception is zaphod, and it is the point of the feature rather than a
        // miss — see below.
        let muchLater = observed.addingTimeInterval(30 * 24 * 60 * 60)
        expect("…and a month later loses only the abandoned scratch tab",
               ReapPolicy.reapable(from: liveMachine, facts: liveFacts, now: muchLater).joined(separator: ", "), "zaphod")
        expect("ford is held by its attached client",
               why(liveMachine[1], among: liveMachine, liveFacts["ford"]!, muchLater), "1 client(s) attached")
        // zaphod is the honest exception, and worth stating rather than
        // hiding: ephemeral, nobody attached, unnamed, running a bare shell,
        // alone in a tab it got from the placeholder name generator. It is what
        // this feature is for, so a month of silence does reach it — which is
        // why the check above is scoped to "not today" rather than "never".
        expect("zaphod is held today by being young and quiet",
               why(liveMachine[8], among: liveMachine, liveFacts["zaphod"]!, observed).hasPrefix("the only pane in its tab") ? "held" : "reapable",
               "held")
        expect("but a whole month of silence does reach it",
               why(liveMachine[8], among: liveMachine, liveFacts["zaphod"]!, muchLater), "reapable")

        // A synthetic wall to test the vetoes one at a time: an orchestrator
        // pane somebody named, and beside it a scratch pane opened yesterday,
        // abandoned, at zero clients, running nothing, its terminal silent
        // since. That last one is what this feature exists to remove.
        let clock = Date(timeIntervalSince1970: 1_800_000_000)
        let yesterday = clock.addingTimeInterval(-13 * 60 * 60)
        let orc = fixture("wall.orc", clients: 1, created: yesterday,
                          labels: ["pos": "v0", "size": "0.5", "tab": "wall", "title": "orc"])
        func scratch(_ extra: [String: String] = [:], clients: Int = 0, created: Date? = yesterday) -> ZmxSession {
            fixture("wall.shell-2", clients: clients, created: created,
                    labels: ["ephemeral": "1", "pos": "v1", "size": "0.5", "tab": "wall"].merging(extra) { _, new in new })
        }
        let abandoned = facts(nil, yesterday)
        func verdictOfScratch(_ pane: ZmxSession, _ known: ReapPolicy.Facts = abandoned) -> String {
            why(pane, among: [orc, pane], known, clock)
        }

        expect("a stale scratch pane is reaped", verdictOfScratch(scratch()), "reapable")
        expect("…and the reaper names it and nothing else",
               ReapPolicy.reapable(from: [orc, scratch()],
                                   facts: ["wall.shell-2": abandoned], now: clock).joined(separator: ", "),
               "wall.shell-2")

        // Each veto on its own, against the pane that would otherwise go.
        expect("an attached client vetoes", verdictOfScratch(scratch(clients: 1)), "1 client(s) attached")
        expect("a title vetoes", verdictOfScratch(scratch(["title": "logs"])), "titled logs")
        expect("a waiting agent vetoes", verdictOfScratch(scratch(["state": "waiting"])), "state=waiting")
        expect("a failed pane vetoes", verdictOfScratch(scratch(["state": "failed"])), "state=failed")
        // Any label outside this build's vocabulary. The namespace is shared
        // with orchestrators, so a pane somebody's script is tracking by a
        // field we have never heard of is a pane somebody is using. Note this
        // deliberately is *not* `ended`/`exit_code` any more: those are the
        // daemon's fields and `Zmx.list` now reserves them, so they no longer
        // reach `labels` and no longer accidentally protect `zmx run` sessions.
        expect("a label we don't understand vetoes",
               verdictOfScratch(scratch(["owner": "trillian"])), "carries owner")
        expect("something running vetoes", verdictOfScratch(scratch(), facts("vim", yesterday)), "running vim")
        expect("no ephemeral mark, no candidate",
               verdictOfScratch(scratch(["ephemeral": ""])), "not ephemeral")
        // Gathered into someone else's wall by an orchestrator: the `tab` label
        // disagrees with the name, and the pane has company there.
        let borrowed = scratch(["tab": "spike"])
        expect("a pane arranged into another tab vetoes",
               why(borrowed, among: [orc, borrowed, fixture("spike.orc", clients: 1, created: yesterday, labels: ["tab": "spike"])],
                   abandoned, clock),
               "gathered into spike")
        // The last pane of a tab waits fourteen times as long rather than
        // forever: thirteen hours of silence takes a surplus pane off a wall
        // and leaves a lone one alone, a week of it takes either.
        expect("the last pane of a tab is not yet old enough",
               why(scratch(), among: [scratch()], abandoned, clock),
               "the only pane in its tab, and only 13.0h old")
        let aWeekOn = clock.addingTimeInterval(8 * 24 * 60 * 60)
        expect("but the last pane of a tab is not immune",
               why(scratch(), among: [scratch()],
                   facts(nil, clock.addingTimeInterval(-8 * 24 * 60 * 60)), aWeekOn),
               "reapable")

        // Not knowing is not permission.
        expect("an unknown creation time vetoes", verdictOfScratch(scratch(created: nil)), "age unknown")
        expect("an unreadable terminal vetoes", verdictOfScratch(scratch(), facts(nil, nil)), "last activity unknown")

        // The thresholds, at the boundary, from both directions.
        func decision(_ pane: ZmxSession, _ known: ReapPolicy.Facts) -> String {
            ReapPolicy.verdict(for: pane, among: [orc, pane], facts: known, now: clock).isReap ? "reap" : "keep"
        }
        let twelveHours: TimeInterval = 12 * 60 * 60
        expect("exactly twelve hours old is old enough",
               decision(scratch(created: clock.addingTimeInterval(-twelveHours)),
                        facts(nil, clock.addingTimeInterval(-twelveHours))), "reap")
        expect("a minute short of twelve hours is not",
               decision(scratch(created: clock.addingTimeInterval(-twelveHours + 60)),
                        facts(nil, yesterday)), "keep")
        expect("a young pane says how young", verdictOfScratch(scratch(created: clock.addingTimeInterval(-11.5 * 3600))),
               "only 11.5h old")
        expect("silence of exactly twelve hours is silent enough",
               decision(scratch(), facts(nil, clock.addingTimeInterval(-twelveHours))), "reap")
        expect("a pane that spoke an hour ago is kept",
               decision(scratch(), facts(nil, clock.addingTimeInterval(-3600))), "keep")
        expect("a recently active pane says when",
               verdictOfScratch(scratch(), facts(nil, clock.addingTimeInterval(-11.5 * 3600))), "active 11.5h ago")

        // Two stale scratch panes in one tab: the tab must survive, so exactly
        // one goes, and it is the older. Evaluating each against the original
        // list rather than the shrinking one would empty the tab.
        let twins = [
            fixture("wall.shell-2", created: yesterday,
                    labels: ["ephemeral": "1", "pos": "v0", "tab": "wall"]),
            fixture("wall.shell-3", created: yesterday.addingTimeInterval(600),
                    labels: ["ephemeral": "1", "pos": "v1", "tab": "wall"]),
        ]
        expect("a tab of two stale panes keeps one",
               ReapPolicy.reapable(from: twins,
                                   facts: ["wall.shell-2": abandoned, "wall.shell-3": abandoned],
                                   now: clock).joined(separator: ", "),
               "wall.shell-2")

        // A dry run over whatever is really running, printed and never acted
        // on. There is no path from here to `zmx kill`: `gatherFacts` reads
        // `ps`, `verdict` is pure, and the killing lives in `runOnLaunch`,
        // which this does not call.
        if live.isEmpty {
            print("skip no live sessions to judge")
        } else {
            let measured = EphemeralReaper.gatherFacts(for: live)
            let rightNow = Date()
            let inAMonth = rightNow.addingTimeInterval(30 * 24 * 60 * 60)
            print("ok   reap dry run (nothing is killed here):")
            for session in live.sorted(by: { $0.name < $1.name }) {
                let known = measured[session.name] ?? ReapPolicy.Facts.unknown
                let now = ReapPolicy.verdict(for: session, among: live, facts: known, now: rightNow).reason
                let later = ReapPolicy.verdict(for: session, among: live, facts: known, now: inAMonth).reason
                // The measured facts alongside the verdict, because the useful
                // question about a surprising verdict is always which fact was
                // missing.
                let age = session.createdAt.map { String(format: "age %.2fh", rightNow.timeIntervalSince($0) / 3600) }
                let quiet = known.lastActivity.map { String(format: "quiet %.2fh", rightNow.timeIntervalSince($0) / 3600) }
                let measurements = [
                    age ?? "no creation time", known.foreground.map { "running \($0)" }, quiet ?? "no terminal found",
                ]
                print("       \(session.name) → now: \(now); in 30 days: \(later) "
                    + "[\(measurements.compactMap { $0 }.joined(separator: ", "))]")
            }
            // The pass itself, which is not quite the sum of the lines above:
            // `reapable` also enforces that a tab keeps a pane, so a tab whose
            // panes all read "reapable" still loses only the older ones.
            let pass = ReapPolicy.reapable(from: live, facts: measured, now: rightNow)
            print("       a reap pass now would kill: \(pass.isEmpty ? "nothing" : pass.joined(separator: ", "))")
        }

        // `ipc.Info`, decoded from a payload captured off a real socket rather
        // than hand-built, because the whole risk in that decoder is that the
        // layout was deduced by hexdump and could be wrong. This one is zmx
        // 0.7.0 answering `.info` for a session created as `bash -i` in
        // /private/tmp with one client attached, whose first `zmx run` task had
        // just exited 7 — every field carrying a value we can name.
        let captured = Data(base64Encoded:
            "AQAAAAAAAAAslAAABwAMAGJhc2ggLWkAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
            "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
            "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
            "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
            "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAvcHJpdmF0ZS90bXAAAAAAAAAAAAAAAAAAAAAA" +
            "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
            "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
            "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
            "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAbqd7agAAAABvp3tq" +
            "AAAAAAcAAAAAAAAA"
        )!
        let info = ZmxInfo.decode(captured)
        expect("info payload is 552 bytes", String(captured.count), "552")
        expect("info clients", String(info?.clients ?? -1), "1")
        expect("info pid", String(info?.pid ?? -1), "37932")
        expect("info command", info?.command ?? "<nil>", "bash -i")
        expect("info start dir", info?.startDirectory ?? "<nil>", "/private/tmp")
        expect("info created at", String(info?.createdAt ?? -1), "1786488686")
        expect("info task ended at", String(info?.taskEndedAt ?? -1), "1786488687")
        expect("info task exit code", String(info?.taskExitCode ?? -1), "7")

        // A daemon that grew or shrank `Info` is something to notice rather
        // than to read half of, so a wrong-sized payload is nil, not a struct
        // full of plausible nonsense.
        expect("a short info payload decodes to nil",
               ZmxInfo.decode(captured.dropLast()) == nil ? "nil" : "decoded", "nil")
        expect("a long info payload decodes to nil",
               ZmxInfo.decode(captured + Data([0])) == nil ? "nil" : "decoded", "nil")

        // When a finished task turns its own pane red. Every rule here exists
        // to stop a poll loop from behaving like an event, or from writing over
        // a signal somebody else put there.
        func flags(_ state: String?, _ code: Int32, _ ended: Int64, _ lastEnded: Int64?) -> String {
            ZmxTaskWatch.shouldFlagFailure(
                state: state, exitCode: code, endedAt: ended, lastEndedAt: lastEnded
            ) ? "failed" : "-"
        }
        expect("a new non-zero exit flags the pane", flags(nil, 7, 200, 100), "failed")
        expect("a new zero exit flags nothing", flags(nil, 0, 200, 100), "-")
        expect("the same completion twice is not a new failure", flags(nil, 7, 200, 200), "-")
        expect("the first sighting of a session only takes a baseline", flags(nil, 7, 200, nil), "-")
        // A session with no task at all reads 0, which must not look like a
        // completion the instant we start watching it.
        expect("a session that has never run a task", flags(nil, 0, 0, nil), "-")
        // An agent asking for a human outranks a report about a build, and a
        // red nobody has acknowledged is already red.
        expect("waiting is never overwritten", flags("waiting", 7, 200, 100), "-")
        expect("failed is not re-asserted", flags("failed", 7, 200, 100), "-")
        // Clocks move backwards across a daemon restart; only forward is news.
        expect("a stamp going backwards is not a completion", flags(nil, 7, 100, 200), "-")

        // Where the file tree roots. The whole feature rests on this being
        // decidable from two strings, one of which is usually absent.
        func root(_ workingDirectory: String?, _ startDir: String?) -> String {
            FileTree.rootPath(workingDirectory: workingDirectory, startDir: startDir) ?? "<none>"
        }
        expect("a live pwd outranks where the session started", root("/tmp/live", "/tmp/start"), "/tmp/live")
        expect("a pane that has never reported falls back", root(nil, "/tmp/start"), "/tmp/start")
        // A session whose shell has no integration reports nothing forever, and
        // an empty string is that, not a directory called "".
        expect("an empty pwd is not a directory", root("", "/tmp/start"), "/tmp/start")
        expect("no focused pane, nothing to show", root(nil, nil), "<none>")
        // OSC 7 carries a URL. libghostty hands over the path, but a shell that
        // emits something odder must not put a scheme in the header.
        expect("a file URL is unwrapped and unescaped", root("file:///tmp/two%20words", nil), "/tmp/two words")
        // Resolving it against *this* process's directory would be a lie about
        // the pane's.
        expect("a relative pwd is refused, not resolved", root("envs/zmxterm", "/tmp/start"), "/tmp/start")
        expect("a trailing slash is not a different directory", root("/tmp/live/", nil), "/tmp/live")

        // Ordering. Dotfiles are in: this is a terminal, and a tree that hides
        // .gitignore is lying about the directory.
        expect(
            "directories first, then case-insensitively",
            names([("b.txt", false), ("Alpha", false), (".git", true), ("zdir", true), ("a.txt", false)]),
            ".git zdir a.txt Alpha b.txt"
        )
        expect("names differing only in case keep a fixed order",
               names([("readme", false), ("README", false)]), "README readme")

        // Path → text to insert. Both this and #13's Finder drop go through it,
        // so the same file has to arrive as the same string either way.
        func insertion(_ path: String, _ cwd: String?) -> String {
            FileTree.insertion(for: path, relativeTo: cwd)
        }
        expect("a file under the pane's directory is relative", insertion("/tmp/a/b.txt", "/tmp/a"), "b.txt ")
        expect("and stays relative further down", insertion("/tmp/a/sub/b.txt", "/tmp/a"), "sub/b.txt ")
        expect("a file outside it is absolute", insertion("/etc/hosts", "/tmp/a"), "/etc/hosts ")
        // The prefix test is on a path component, not on characters: /tmp/apple
        // is not inside /tmp/a.
        expect("a sibling sharing a prefix is not inside", insertion("/tmp/apple/x", "/tmp/a"), "/tmp/apple/x ")
        expect("the directory itself is .", insertion("/tmp/a", "/tmp/a"), ". ")
        expect("with no directory to compare against, absolute", insertion("/tmp/a/b.txt", nil), "/tmp/a/b.txt ")
        expect("a space is quoted", insertion("/tmp/a/two words.txt", "/tmp/a"), "'two words.txt' ")
        // A single quote cannot appear inside single quotes; it is closed,
        // escaped, reopened.
        expect("a quote is quoted", insertion("/tmp/a/it's.txt", "/tmp/a"), "'it'\\''s.txt' ")
        expect("a leading tilde is quoted rather than left to expand",
               insertion("/tmp/a/~backup", "/tmp/a"), "'~backup' ")
        // Nothing is executed by inserting a path, and the trailing space is
        // what lets a second one follow.
        expect("nothing inserted ends a line",
               insertion("/tmp/a/b.txt", "/tmp/a").contains("\n") ? "newline" : "none", "none")

        // Several files at once — a multi-file drop from Finder (#13). The same
        // rule per path, and the trailing space each already carries is what
        // separates them, so nothing joins and nothing doubles.
        func drop(_ paths: [String], _ cwd: String?) -> String {
            FileTree.insertion(for: paths, relativeTo: cwd)
        }
        expect("several files are one command line",
               drop(["/tmp/a/b.txt", "/tmp/a/c.txt"], "/tmp/a"), "b.txt c.txt ")
        expect("each is quoted on its own",
               drop(["/tmp/a/two words.txt", "/tmp/a/c.txt"], "/tmp/a"), "'two words.txt' c.txt ")
        expect("inside and outside the directory can mix",
               drop(["/tmp/a/b.txt", "/etc/hosts"], "/tmp/a"), "b.txt /etc/hosts ")
        // Finder hands over a selection in the order it was made, and `cp a b`
        // is not `cp b a`. Nothing here sorts.
        expect("the order dropped is the order inserted",
               drop(["/tmp/a/c.txt", "/tmp/a/b.txt"], "/tmp/a"), "c.txt b.txt ")
        expect("dropping nothing inserts nothing", drop([], "/tmp/a"), "")
        expect("one file is the same as the single-path rule",
               drop(["/tmp/a/b.txt"], "/tmp/a"), insertion("/tmp/a/b.txt", "/tmp/a"))
        // The hazard the ticket names: a filename may legally contain a
        // newline, and an unquoted one would be a command that runs. Quoting is
        // what defuses it — the newline lands *inside* the quotes, so the shell
        // is still waiting for the close rather than executing anything.
        let sneaky = drop(["/tmp/a/oops\nrm -rf ~"], "/tmp/a")
        expect("a newline in a filename stays inside the quotes",
               sneaky, "'oops\nrm -rf ~' ")
        expect("and the quoting is what makes that safe",
               sneaky.hasPrefix("'") && sneaky.hasSuffix("' ") ? "quoted" : "bare", "quoted")

        // Which rows are on screen. Lazily loaded means "expanded" and "listed"
        // are different states, and both are visible here.
        let treeRoot = FileEntry(path: "/r", name: "r", isDirectory: true)
        let listed: [String: [FileEntry]] = [
            "/r": [
                FileEntry(path: "/r/d", name: "d", isDirectory: true),
                FileEntry(path: "/r/slow", name: "slow", isDirectory: true),
                // A link back to the root: expanding it would produce an
                // infinite tree one click at a time.
                FileEntry(path: "/r/loop", name: "loop", isDirectory: true, resolvedPath: "/r"),
                FileEntry(path: "/r/f.txt", name: "f.txt", isDirectory: false),
            ],
            "/r/d": [FileEntry(path: "/r/d/x.txt", name: "x.txt", isDirectory: false)],
            "/r/loop": [FileEntry(path: "/r/loop/d", name: "d", isDirectory: true)],
        ]
        expect("a closed tree is one level",
               rowShape(FileTree.rows(root: treeRoot, children: listed, expanded: [])),
               "d0 slow0 loop0! f.txt0")
        expect("an open folder brings its children with it",
               rowShape(FileTree.rows(root: treeRoot, children: listed, expanded: ["/r/d"])),
               "d0* x.txt1 slow0 loop0! f.txt0")
        expect("a folder opened before its listing arrives says so",
               rowShape(FileTree.rows(root: treeRoot, children: listed, expanded: ["/r/slow"])),
               "d0 slow0… loop0! f.txt0")
        expect("a symlink loop is shown and not descended",
               rowShape(FileTree.rows(root: treeRoot, children: listed, expanded: ["/r/loop"])),
               "d0 slow0 loop0! f.txt0")

        // The reader. Everything that decides what gets typed into somebody's
        // shell is a pure function, which is the only way to argue about it
        // without a viewer installed and a document open. Since #25 that starts
        // one step earlier: which rule the file picked is a pure function too,
        // of the path and a predicate saying what is installed.

        // The list from the ticket, parsed exactly as written.
        let example = Reader.parse("""
        # what I read things with
        *.md              mdv --watch {path}
        *.log *.jsonl     tail -f {path} | humanlog
        *                 bat --paging=always {path}
        """)
        expect("a viewer list is read line by line", "\(example.rules.count)", "3")
        expect("comments and blanks are not rules", example.problem ?? "<none>", "<none>")
        expect("a rule can name several patterns",
               example.rules[1].patterns.joined(separator: " "), "*.log *.jsonl")
        expect("the command is everything after the gap",
               example.rules[1].command, "tail -f {path} | humanlog")
        // The gap is the delimiter, so a command keeps its own single spaces.
        // With no gap at all the first word is the pattern, because a rule that
        // silently did nothing because someone typed one space is a bad trade.
        expect("a single-spaced rule is still a rule",
               Reader.parse("*.md mdv --watch {path}").rules.first?.command ?? "<none>",
               "mdv --watch {path}")
        expect("a tab separates as well as a gap",
               Reader.parse("*.md\tmdv --watch {path}").rules.first?.command ?? "<none>",
               "mdv --watch {path}")

        // First match wins, and a later rule never shadows an earlier one.
        let installed: (Reader.Rule) -> Bool = { _ in true }
        expect("the first matching rule wins",
               describe(Reader.match(path: "/tmp/a/notes.md", in: example.rules, isInstalled: installed)),
               "mdv --watch {path}")
        expect("a later rule does not shadow an earlier one",
               describe(Reader.match(path: "/tmp/a/run.log", in: example.rules, isInstalled: installed)),
               "tail -f {path} | humanlog")
        expect("the unconditional rule catches the rest",
               describe(Reader.match(path: "/tmp/a/pic.png", in: example.rules, isInstalled: installed)),
               "bat --paging=always {path}")
        expect("a name is matched, not a path",
               describe(Reader.match(path: "/var/log/thing.png", in: example.rules, isInstalled: installed)),
               "bat --paging=always {path}")
        expect("case does not decide it",
               describe(Reader.match(path: "/tmp/a/README.MD", in: example.rules, isInstalled: installed)),
               "mdv --watch {path}")
        // A list with no unconditional rule leaves files with nothing to open
        // them, which is a thing to say rather than a thing to guess at.
        expect("no rule matching at all is its own answer",
               describe(Reader.match(path: "/tmp/a/pic.png", in: Array(example.rules.prefix(2)),
                                     isInstalled: installed)),
               "<no rule>")

        // **A rule whose viewer is missing falls through to the next match.**
        // Degrading to a worse viewer beats degrading to nothing.
        let noMdv: (Reader.Rule) -> Bool = { !$0.executables.contains("mdv") }
        expect("a missing viewer falls through to the next match",
               describe(Reader.match(path: "/tmp/a/notes.md", in: example.rules, isInstalled: noMdv)),
               "bat --paging=always {path}")
        let nothing: (Reader.Rule) -> Bool = { _ in false }
        expect("and names everything it tried when none of them is there",
               describe(Reader.match(path: "/tmp/a/notes.md", in: example.rules, isInstalled: nothing)),
               "missing mdv, bat")
        // A pipeline is only usable if both halves are: checking the first would
        // open a pane onto `humanlog: command not found`.
        expect("a pipeline names every binary it needs",
               example.rules[1].executables.joined(separator: " "), "tail humanlog")

        // {path} is a placeholder, not an append — a `tail -f {path} | humanlog`
        // has nowhere sensible to put a file at the end of the line.
        let mdv = example.rules[0]
        expect("a document goes where the rule says",
               mdv.commandLine(opening: "/tmp/a/notes.md"), "mdv --watch /tmp/a/notes.md")
        expect("a path with a space survives quoted",
               mdv.commandLine(opening: "/tmp/a/two words.md"), "mdv --watch '/tmp/a/two words.md'")
        expect("{path} twice is substituted twice",
               Reader.Rule(patterns: ["*"], command: "diff {path} {path}")
                   .commandLine(opening: "/tmp/a/two words.md"),
               "diff '/tmp/a/two words.md' '/tmp/a/two words.md'")
        // #20's readerCommand was "everything before the path", and a rule
        // written that way still means what its author meant.
        expect("a rule with no placeholder gets the path appended",
               Reader.Rule(patterns: ["*"], command: "glow -p").commandLine(opening: "/tmp/a/notes.md"),
               "glow -p /tmp/a/notes.md")

        // The stop key belongs to the rule: `q` quits mdv and bat's pager, and a
        // tail stops for nothing but ^C.
        expect("a rule stops with q unless it says otherwise", mdv.quitKey, "q")
        let tail = Reader.parse("*.log  quit=^C  tail -f {path}").rules[0]
        expect("caret notation becomes the byte", visible(tail.quitKey), "^C")
        expect("and the option is not part of the command", tail.command, "tail -f {path}")
        expect("an empty stop key is honoured rather than replaced",
               "[" + Reader.parse("*.log  quit=  tail -f {path}").rules[0].quitKey + "]", "[]")
        // The #22 workaround is a plausible thing to configure, and it is an
        // assignment for the shell rather than an option for us.
        let kitty = Reader.parse("*.md  TERM=xterm-kitty mdv --watch {path}").rules[0]
        expect("leading assignments stay in the command",
               kitty.command, "TERM=xterm-kitty mdv --watch {path}")
        expect("and are not mistaken for the viewer", kitty.viewer, "mdv")
        expect("a viewer given by path is named by its last component",
               Reader.Rule(patterns: ["*"], command: "/usr/local/bin/glow -p").viewer, "glow")

        // ^U kills whatever the stop key left on the prompt; \r is Return. This
        // holds whatever the stop was, which is the point: ^C flushes the tty's
        // input queue, so the command line is always a later write than the
        // thing that stopped the last viewer, and always re-clears the line.
        expect("what actually reaches the pty",
               visible(Reader.keystrokes(mdv, opening: "/tmp/a/notes.md")),
               "^U mdv --watch /tmp/a/notes.md CR")
        expect("a ^C rule still clears the line before typing",
               visible(Reader.keystrokes(tail, opening: "/tmp/a/run.log")),
               "^U tail -f /tmp/a/run.log CR")

        // A malformed file loses the line that is wrong and nothing else.
        // libghostty rejects its whole config over one bad key — see CLAUDE.md,
        // where it is written down as a failure mode that cost hours.
        let mixed = Reader.parse("""
        *.md   mdv --watch {path}
        *.log
        *      bat {path}
        """)
        expect("a bad line loses itself and not the file", "\(mixed.rules.count)", "2")
        expect("and the file says which line", mixed.problem?.contains("line 2") == true ? "named" : "vague",
               "named")
        // Only a file with nothing usable left in it falls back — and says so.
        let empty = Reader.load(path: write("""
        this file is prose
        so is this
        """), command: nil, quitKey: nil)
        expect("a file with no usable rule falls back to the built-ins",
               "\(empty.rules == Reader.builtin)", "true")
        expect("and says so", empty.problem?.contains("built-in") == true ? "said" : "silent", "said")
        expect("a file that parses is the whole list",
               "\(Reader.load(path: write("*  bat {path}"), command: nil, quitKey: nil).rules.count)", "1")
        // No file and no defaults: the built-ins, which are themselves parsed
        // from config text, so a format they cannot express is one the file
        // cannot either.
        expect("with no file at all the built-ins stand",
               "\(Reader.load(path: nil, command: nil, quitKey: nil).rules == Reader.builtin)", "true")
        expect("every built-in rule runs something",
               flag(Reader.builtin.allSatisfy { !$0.executables.isEmpty }), "yes")
        // #20's single viewer was documented and somebody wrote it down.
        let legacy = Reader.load(path: nil, command: "glow -p", quitKey: "x")
        expect("a readerCommand still opens everything",
               describe(Reader.match(path: "/tmp/a/pic.png", in: legacy.rules, isInstalled: installed)),
               "glow -p")
        expect("with its own quit key", legacy.rules[0].quitKey, "x")
        try? FileManager.default.removeItem(at: configFixtures)

        // Which pane a document goes to, and the promise that a second document
        // does not build a second reader.
        let readerPanes = [
            labelled("zaphod.shell-1", ["tab": "zaphod"]),
            labelled("zaphod.shell-2", ["tab": "zaphod", "reader": "1"]),
            labelled("ford.shell-1", ["tab": "ford", "reader": "1"]),
        ]
        expect("the tab's reader is found",
               Reader.pane(among: readerPanes, tab: "zaphod")?.name ?? "<none>", "zaphod.shell-2")
        expect("another tab's reader is not borrowed",
               Reader.pane(among: readerPanes, tab: "marvin")?.name ?? "<none>", "<none>")
        expect("a tab with no reader has none",
               Reader.pane(among: [readerPanes[0]], tab: "zaphod")?.name ?? "<none>", "<none>")
        expect("reader is a bare flag", flag(readerPanes[1].isReader), "yes")
        expect("and absent means not one", flag(readerPanes[0].isReader), "no")

        // Whether the thing in the reader is ours to stop. This is asked of the
        // pid we watched start, never of the name: a pipeline is two processes
        // under one shell and the name that comes back is whichever the scan
        // reached first, and a tail never exits, so a name-based "still
        // running?" would refuse the next document forever.
        expect("an idle reader is typed into", plan(foreground: nil, started: nil), "start")
        expect("the process we started is ours to stop",
               plan(foreground: (4242, "humanlog"), started: 4242), "swap")
        expect("even one that never ends", plan(foreground: (4242, "tail"), started: 4242), "swap")
        expect("a stranger in the reader is refused",
               plan(foreground: (99, "vim"), started: 4242), "busy vim")
        // The memory is in-process. After a restart the viewer still running in
        // a reader is somebody else's as far as this is concerned, and refusing
        // is the safe direction to be wrong in.
        expect("and so is anything we did not watch start",
               plan(foreground: (4242, "mdv"), started: nil), "busy mdv")

        // What the panel says when nothing opened. Each of these is a thing to
        // go and fix, so each has to name it.
        expect("opening reports no problem", Reader.Outcome.opened(pane: "x").problem ?? "<none>", "<none>")
        expect("a busy reader names what is in it",
               Reader.Outcome.busy(pane: "zaphod.shell-2", running: "vim").problem?
                   .contains("running vim") == true ? "named" : "vague", "named")
        expect("a missing viewer names what it tried",
               Reader.Outcome.missingViewer(["mdv", "glow"]).problem?
                   .contains("mdv, glow") == true ? "named" : "vague", "named")
        expect("and where the rules live",
               Reader.Outcome.missingViewer(["mdv"]).problem?
                   .contains("viewers.conf") == true ? "named" : "vague", "named")
        expect("an unmatched file names itself, not its path",
               Reader.Outcome.noRule("/tmp/a/pic.xyz").problem?
                   .contains("pic.xyz") == true ? "named" : "vague", "named")

        // What this build would actually run — the one part of the reader that
        // depends on the machine, so it reports rather than fails. It answers
        // the question a failed Open in Reader raises: which rules are in force,
        // and can the login shell find the viewers they name.
        let effective = Reader.rules
        print("note reader rules: \(effective.rules.count) from "
            + (FileManager.default.fileExists(atPath: Reader.configPath) ? Reader.configPath : "built-in defaults"))
        for rule in effective.rules {
            print("note   \(rule.patterns.joined(separator: " ")) → \(rule.command)"
                + " [stop \(rule.quitKey.isEmpty ? "<signal only>" : visible(rule.quitKey))]"
                + " \(Reader.isInstalled(rule) ? "installed" : "not installed")")
        }
        if let problem = effective.problem { print("note   problem: \(problem)") }

        // Searching a path list is pure, so the part that decides "is it there"
        // is checkable without a shell at all.
        let bin = FileManager.default.temporaryDirectory.appendingPathComponent("zmxterm-selftest-bin")
        try? FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let fake = bin.appendingPathComponent("pretend-viewer")
        FileManager.default.createFile(atPath: fake.path, contents: Data("#!/bin/sh\n".utf8),
                                       attributes: [.posixPermissions: 0o755])
        func rule(_ command: String) -> Reader.Rule { Reader.Rule(patterns: ["*"], command: command) }
        expect("a viewer on the searched path is found",
               flag(Reader.isInstalled(rule("pretend-viewer"), searching: [bin.path])), "yes")
        expect("and is not found when that directory is not searched",
               flag(Reader.isInstalled(rule("pretend-viewer"), searching: ["/usr/bin"])), "no")
        expect("an absolute viewer skips the path entirely",
               flag(Reader.isInstalled(rule(fake.path), searching: [])), "yes")
        expect("a non-executable file is not a viewer",
               flag(Reader.isInstalled(rule("/etc/hosts"), searching: [])), "no")
        expect("a pipeline needs both halves",
               flag(Reader.isInstalled(rule("pretend-viewer | nope-viewer"), searching: [bin.path])), "no")
        expect("and is installed when it has them",
               flag(Reader.isInstalled(rule("pretend-viewer | pretend-viewer"), searching: [bin.path])), "yes")
        try? FileManager.default.removeItem(at: bin)

        // The login PATH itself depends on the machine, so it reports. It is
        // worth printing because the bug it replaced was invisible from a
        // terminal: `zsh -lc` skips `.zshrc`, so a viewer installed somewhere
        // `.zshrc` adds to PATH read as missing to the app and present to
        // everyone testing by hand. Run this under `env -i HOME=$HOME
        // USER=$USER` to see what a Dock launch sees.
        print("note login PATH: \(Reader.loginPath.count) entries"
            + (Reader.loginPath.isEmpty ? "" : ", first \(Reader.loginPath.prefix(3).joined(separator: ":"))"))

        // The editor. Which command runs, and what reaches the pty, are pure
        // functions of two strings — which is the whole of what #26 decides,
        // because everything after that is `split` doing what Split Right does.
        //
        // The order is override, then the login shell's EDITOR, then vim. The
        // middle step is the point of the ticket: somebody who has set EDITOR
        // has answered this already, and a second place to answer it is a
        // second place for the two to disagree.
        expect("an override wins",
               Editor.command(override: "hx", environment: "nano"), "hx")
        expect("the login shell's EDITOR is used when nothing overrides it",
               Editor.command(override: nil, environment: "nano"), "nano")
        expect("and vim is the fallback when neither says anything",
               Editor.command(override: nil, environment: ""), "vim")
        // Whitespace is not an answer. A `defaults write … editorCommand " "`
        // and an unset EDITOR that printf rendered as a blank line both mean
        // "nothing configured", and both used to be able to reach the shell as
        // a command that is not a command.
        expect("a blank override is not an opinion",
               Editor.command(override: "   ", environment: "nano"), "nano")
        expect("nor is a blank EDITOR",
               Editor.command(override: nil, environment: "  \n"), "vim")

        // EDITOR is a command line, not a binary — `code -w` has to keep its
        // argument, or the editor returns immediately and the pane is idle.
        expect("EDITOR keeps its arguments",
               Editor.command(override: nil, environment: "code -w"), "code -w")
        expect("and the file goes after them",
               Reader.commandLine(Editor.command(override: nil, environment: "code -w"),
                                  opening: "/tmp/a/notes.md"),
               "code -w /tmp/a/notes.md")
        // The same quoting the tree inserts paths with, because a filename with
        // a space is the common case rather than the exotic one.
        expect("a path with a space survives quoted",
               Reader.commandLine("vim", opening: "/tmp/a/two words.md"),
               "vim '/tmp/a/two words.md'")
        expect("an editor can put the file somewhere other than the end",
               Reader.commandLine("hx {path} +10", opening: "/tmp/a/notes.md"),
               "hx /tmp/a/notes.md +10")
        // Which binary is checked for. Not the basename: an EDITOR naming a
        // path has to be asked about at that path, or a different binary of the
        // same name on the PATH answers for it.
        expect("the binary is the first word",
               Editor.executable(of: "code -w"), "code")
        expect("an absolute editor keeps its path",
               Editor.executable(of: "/opt/homebrew/bin/nvim"), "/opt/homebrew/bin/nvim")
        expect("and a leading assignment is not the editor",
               Editor.executable(of: "VISUAL=1 nvim"), "nvim")
        // What reaches the pty. Return at the end, and no quit key anywhere —
        // an editor is never stopped by this app, which is the other half of
        // the rule that keeps it out of the reader.
        expect("what actually reaches the pty",
               visible(Reader.keystrokes(command: "vim", opening: "/tmp/a/notes.md")),
               "^U vim /tmp/a/notes.md CR")
        // The message names the editor it looked for and where it looked, since
        // both are things to go and fix.
        expect("a missing editor names itself",
               Reader.Outcome.missingEditor("hx").problem?.contains("hx") == true ? "named" : "vague",
               "named")
        expect("and says where it looked",
               Reader.Outcome.missingEditor("hx").problem?
                   .contains("login shell's PATH") == true ? "named" : "vague", "named")
        expect("and how to fix it",
               Reader.Outcome.missingEditor("hx").problem?
                   .contains("editorCommand") == true ? "named" : "vague", "named")

        // What this build would open, which depends on the machine and so
        // reports. It answers the question a failed Open in Editor raises.
        let editor = Editor.command()
        print("note editor: \(editor)"
            + " [\(Reader.isInstalled(executable: Editor.executable(of: editor)) ? "installed" : "not installed")]"
            + " EDITOR=\(Reader.login.editor.isEmpty ? "<unset>" : Reader.login.editor)")
        // MARK: Today's daily note

        // Which file, and the reason the date is a parameter: "does the path
        // change at midnight" cannot be asked of a function that reads the
        // clock itself.
        let lisbon = TimeZone(identifier: "Europe/Lisbon")!
        func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int,
                _ zone: TimeZone = lisbon) -> Date
        {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            return calendar.date(from: DateComponents(
                year: year, month: month, day: day, hour: hour, minute: minute
            ))!
        }
        let template = "Daily/{yyyy-MM-dd}.md"
        expect("today's note", Daily.relativePath(template, on: at(2026, 8, 12, 9, 0), timeZone: lisbon),
               "Daily/2026-08-12.md")
        expect("a minute before midnight is still today",
               Daily.relativePath(template, on: at(2026, 8, 12, 23, 59), timeZone: lisbon),
               "Daily/2026-08-12.md")
        expect("a minute after it is tomorrow",
               Daily.relativePath(template, on: at(2026, 8, 13, 0, 1), timeZone: lisbon),
               "Daily/2026-08-13.md")
        // The same instant, two zones. A daily note belongs to the local day,
        // which is why the zone is a parameter rather than UTC.
        expect("the day is the reader's, not the file's",
               Daily.relativePath(template, on: at(2026, 8, 12, 23, 59), timeZone: lisbon),
               Daily.relativePath(template, on: at(2026, 8, 13, 0, 59, TimeZone(identifier: "Europe/Riga")!),
                                  timeZone: lisbon))
        expect("several formats in one path",
               Daily.relativePath("{yyyy}/{MM}/{dd}-log.md", on: at(2026, 8, 12, 9, 0), timeZone: lisbon),
               "2026/08/12-log.md")
        expect("a template with no date at all is a path",
               Daily.relativePath("Inbox.md", on: at(2026, 8, 12, 9, 0), timeZone: lisbon), "Inbox.md")
        // A typo comes back visible rather than swallowed, so the "no note"
        // message names a path somebody can recognise as wrong.
        expect("an unclosed brace stays literal",
               Daily.relativePath("Daily/{yyyy-MM-dd.md", on: at(2026, 8, 12, 9, 0), timeZone: lisbon),
               "Daily/{yyyy-MM-dd.md")
        expect("root and note are joined once",
               Daily.absolutePath(root: "/vault", relative: "Daily/x.md"), "/vault/Daily/x.md")

        // The parse. Everything the panel shows is decided here.
        let note = """
        ## Solid

        - The agents that build Solid now outlive the windows that show them
          - Built overnight and shipped as [zmxterm](https://github.com/riclib/zmxterm)
          - The agents drive it without being given an API

        - **Solid's data projections can now grow new columns o**ver all previously collected history
          - S-2169: the run timeline's step lanes now link to the child pipelines

        + A plus is a bullet too
        * And so is a star

        ```sh
        - this is a shell transcript, not an entry
        ```

        \t- a tab-indented bullet is somebody's detail
          * so is this one
        -no space, so not a bullet
        ---
        - [ ] a task is still an entry
        """
        func lines(_ bullets: [Daily.Bullet]) -> String {
            bullets.map { String($0.text.prefix(24)) }.joined(separator: " | ")
        }
        expect("newest first, top level only, everything else ignored",
               lines(Daily.bullets(in: note)),
               "[ ] a task is still an e | And so is a star | A plus is a bullet too | "
                   + "**Solid's data projectio | The agents that build So")
        expect("nested bullets are not entries",
               "\(Daily.bullets(in: note).contains { $0.text.hasPrefix("Built overnight") })", "false")
        expect("nor is a line inside a fence",
               "\(Daily.bullets(in: note).contains { $0.text.contains("shell transcript") })", "false")
        expect("nor a marker with no space after it",
               "\(Daily.bullets(in: note).contains { $0.text.contains("no space") })", "false")
        // A fence closes on the character that opened it, so a ``` inside a
        // ~~~ block does not end it early and swallow the rest of the note.
        expect("a fence of one kind does not close on the other",
               lines(Daily.bullets(in: "~~~\n```\n- inside\n~~~\n- outside")), "outside")
        expect("fewer than twelve is all of them",
               "\(Daily.bullets(in: "- a\n- b\n- c").count)", "3")
        let many = (1 ... 20).map { "- entry \($0)" }.joined(separator: "\n")
        expect("more than twelve stops at twelve", "\(Daily.bullets(in: many).count)", "12")
        expect("and they are the last twelve, newest first",
               lines(Daily.bullets(in: many)).components(separatedBy: " | ").first ?? "", "entry 20")
        expect("a note with no bullets has none", "\(Daily.bullets(in: "# Title\n\nprose").count)", "0")

        // Inline markdown, and the line that made it a requirement: the
        // emphasis markers in the real note are a word out of place. Markdown
        // does not reject that — it bolds the wrong half — and what matters is
        // that every character still arrives.
        func shown(_ markdown: String) -> String { String(Daily.attributed(markdown).characters) }
        expect("markers are consumed, text is not",
               shown("**Solid's data projections can now grow new columns o**ver all history"),
               "Solid's data projections can now grow new columns over all history")
        expect("a link keeps its label", shown("shipped as [zmxterm](https://example.com) today"),
               "shipped as zmxterm today")
        expect("a wikilink is left alone", shown("see [[Conventions]] for the rule"),
               "see [[Conventions]] for the rule")
        expect("an unterminated marker does not eat the line",
               shown("half **bold and then nothing"), "half **bold and then nothing")
        // Measured, and worth writing down rather than fixing: this parser
        // reads `~x~` as strikethrough, so a *path* pasted into a bullet loses
        // its tildes the way bold loses its asterisks. Every word survives —
        // which is the promise — but the string is not the string. Escaping
        // markdown before rendering markdown would be the wrong cure.
        expect("a tilde pair is strikethrough like any other markup",
               shown("iCloud~com~octarine~notes/Documents"), "iCloudcomoctarine~notes/Documents")
        expect("and an unpaired one is left alone", shown("a ~ b"), "a ~ b")

        // The URL, per adapter. Only this part is app-specific, and it is one
        // line each — which is the claim the whole module rests on.
        func opens(_ id: String, vault: String, path: String) -> String {
            guard let adapter = Daily.adapter(named: id) else { return "<no adapter>" }
            return Daily.url(adapter, vault: vault, path: path)?.absoluteString ?? "<no url>"
        }
        expect("Obsidian", opens("obsidian", vault: "Notes", path: "Daily/2026-08-12.md"),
               "obsidian://open?vault=Notes&file=Daily%2F2026-08-12.md")
        expect("Octarine", opens("octarine", vault: "Solid", path: "Daily/2026-08-12.md"),
               "octarine://open?path=Daily%2F2026-08-12.md&workspace=Solid")
        // Spaces are ordinary in a vault name and a note title, and `/` inside
        // a parameter value has to be escaped or the app reads the query as
        // structure. `.urlQueryAllowed` would pass both `/` and `&` through.
        expect("a space in the vault name", opens("obsidian", vault: "My Vault", path: "a.md"),
               "obsidian://open?vault=My%20Vault&file=a.md")
        expect("a slash and an ampersand in the path",
               opens("obsidian", vault: "v", path: "Daily/Q&A.md"),
               "obsidian://open?vault=v&file=Daily%2FQ%26A.md")
        expect("no vault name is refused rather than aimed at the wrong one",
               opens("obsidian", vault: "", path: "a.md"), "<no url>")
        expect("and an unknown app is not one", opens("notion", vault: "v", path: "a.md"), "<no adapter>")
        // The escape hatch: an app nobody has written two lines for still works.
        expect("a raw template is an adapter",
               opens("logseq://x-callback-url/open?page={path}", vault: "", path: "Daily/a.md"),
               "logseq://x-callback-url/open?page=Daily%2Fa.md")
        expect("a raw template naming no vault needs none",
               flag(Daily.adapter(named: "app://open?f={path}")?.needsVault == false), "yes")
        expect("every built-in adapter builds a URL",
               flag(Daily.adapters.allSatisfy {
                   Daily.url($0, vault: "v", path: "Daily/a.md") != nil
               }), "yes")

        // Configuration, which is nothing until it is all there. Each missing
        // piece hides the panel, and each says which piece it was — the
        // diagnosis is for this report, because a feature that hides itself is
        // otherwise impossible to debug.
        func configured(_ adapter: String?, _ vault: String?, _ root: String?, _ path: String?) -> String {
            Daily.settings(adapter: adapter, vault: vault, root: root, template: path) == nil
                ? "hidden" : "shown"
        }
        expect("nothing set at all", configured(nil, nil, nil, nil), "hidden")
        expect("everything set", configured("octarine", "Solid", "~/vault", "Daily/{yyyy-MM-dd}.md"), "shown")
        expect("no root", configured("octarine", "Solid", nil, "Daily/{yyyy-MM-dd}.md"), "hidden")
        expect("no template", configured("octarine", "Solid", "~/vault", nil), "hidden")
        expect("an app that names a vault, with no vault named",
               configured("octarine", "  ", "~/vault", "Daily/{yyyy-MM-dd}.md"), "hidden")
        expect("a raw template that names none does not need one",
               configured("app://open?f={path}", nil, "~/vault", "Daily/{yyyy-MM-dd}.md"), "shown")
        expect("and the reason is sayable",
               Daily.diagnosis(adapter: "octarine", vault: nil, root: "~/v", template: "d.md")
                   .contains(Daily.vaultDefaultsKey) ? "named" : "vague", "named")
        expect("a tilde is expanded, because a path template is not a shell",
               Daily.settings(adapter: "octarine", vault: "S", root: "~/vault", template: "d.md")?
                   .root.hasPrefix("/") == true ? "absolute" : "literal", "absolute")
        // An SF Symbol that does not exist on this macOS draws nothing at all,
        // and a rail button with no glyph is indistinguishable from a bug in
        // the layout. Same check the pane icons get, for the same reason.
        for item in InspectorPanel.allCases {
            expect("panel icon \(item.icon) resolves",
                   NSImage(systemSymbolName: item.icon, accessibilityDescription: nil) != nil
                       ? "loaded" : "missing", "loaded")
        }
        expect("panels available with a daily note",
               InspectorPanel.available(daily: true).map(\.rawValue).joined(separator: ","), "files,daily")
        expect("and without one", InspectorPanel.available(daily: false).map(\.rawValue).joined(separator: ","),
               "files")

        // What is actually on disk, including the case that must never read as
        // "no work today": an iCloud file that has been evicted leaves a hidden
        // placeholder where it was, and `fileExists` says no to both that and a
        // note that was never written.
        let vault = FileManager.default.temporaryDirectory.appendingPathComponent("zmxterm-selftest-vault")
        try? FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        let present = vault.appendingPathComponent("2026-08-12.md").path
        try? "- an entry".write(toFile: present, atomically: true, encoding: .utf8)
        expect("a note that is there is read", describe(Daily.read(present)), "text")
        expect("a note that was never written is missing",
               describe(Daily.read(vault.appendingPathComponent("2026-08-11.md").path)), "missing")
        let evicted = vault.appendingPathComponent("2026-08-10.md").path
        expect("the placeholder is where iCloud leaves it",
               (Daily.placeholderPath(for: evicted) as NSString).lastPathComponent, ".2026-08-10.md.icloud")
        FileManager.default.createFile(atPath: Daily.placeholderPath(for: evicted), contents: Data())
        expect("an evicted note is downloading, not absent", describe(Daily.read(evicted)), "downloading")
        try? FileManager.default.removeItem(at: vault)

        // What this machine would actually show, which depends on defaults
        // nobody else has, so it reports rather than fails.
        if let settings = Daily.settings {
            let relative = Daily.relativePath(settings.template, on: Date())
            let absolute = Daily.absolutePath(root: settings.root, relative: relative)
            let state = Daily.read(absolute)
            print("note daily: \(settings.adapter.name) \(settings.vault) → \(absolute) [\(describe(state))]")
            if case let .text(markdown) = state {
                print("note   \(Daily.bullets(in: markdown).count) of "
                    + "\(Daily.bullets(in: markdown, limit: .max).count) top-level entries shown")
            }
        } else {
            print("note daily: \(Daily.diagnosis(adapter: UserDefaults.standard.string(forKey: Daily.adapterDefaultsKey), vault: UserDefaults.standard.string(forKey: Daily.vaultDefaultsKey), root: UserDefaults.standard.string(forKey: Daily.rootDefaultsKey), template: UserDefaults.standard.string(forKey: Daily.templateDefaultsKey)))")
        }

        // The round trip itself, which needs a daemon and so reports rather
        // than fails — the layout above was read off exactly these bytes, and
        // the cheapest way to notice a zmx release moving a field is to see the
        // pid stop matching the one `zmx list` printed a line earlier.
        if live.isEmpty {
            print("skip no live sessions to ask for info")
        } else {
            for session in live.sorted(by: { $0.name < $1.name }) {
                guard let info = ZmxClient.info(session: session.name) else {
                    print("FAIL info \(session.name): no reply"); failures += 1; continue
                }
                let agrees = String(info.pid) == session.pid
                if !agrees { failures += 1 }
                print("\(agrees ? "ok  " : "FAIL") info \(session.name): pid \(info.pid), "
                    + "clients \(info.clients), task ended \(info.taskEndedAt) exit \(info.taskExitCode)")
            }
        }

        print(failures == 0 ? "\nall passed" : "\n\(failures) failed")
        return failures == 0 ? 0 : 1
    }

    private static func positioned(_ name: String, _ position: String?, _ size: Double?) -> ZmxSession {
        var labels: [String: String] = [:]
        if let position { labels["pos"] = position }
        if let size { labels["size"] = String(size) }
        return ZmxSession(name: name, pid: "1", clients: 1, startDir: "/tmp", command: "zsh", labels: labels)
    }

    private static func labelled(_ name: String, _ labels: [String: String]) -> ZmxSession {
        ZmxSession(name: name, pid: "1", clients: 1, startDir: "/tmp", command: "zsh", labels: labels)
    }

    /// The pane as it is after `ZmxRegistry.removeFromTab`, modelled by dropping
    /// exactly the labels that command clears.
    private static func unplaced(_ pane: ZmxSession) -> ZmxSession {
        var labels = pane.labels
        for key in ZmxSession.placementLabels { labels.removeValue(forKey: key) }
        return labelled(pane.name, labels)
    }

    private static func flag(_ value: Bool) -> String { value ? "yes" : "no" }

    /// The state of a note file, named rather than dumped: `.text` carries the
    /// whole note, and a failure message quoting seventeen kilobytes of
    /// somebody's day helps nobody.
    private static func describe(_ note: Daily.Note) -> String {
        switch note {
        case .missing: "missing"
        case .downloading: "downloading"
        case .text: "text"
        case let .unreadable(reason): "unreadable: \(reason)"
        }
    }

    private static let configFixtures = FileManager.default.temporaryDirectory
        .appendingPathComponent("zmxterm-selftest-conf")

    /// A viewer list on disk. `Reader.parse` can be tested on a string, but the
    /// fallback to the built-in defaults is a claim about a *file* — that one
    /// nobody can read leaves you with working viewers rather than none — and
    /// the only honest way to check that is to hand it one.
    private static func write(_ text: String) -> String {
        try? FileManager.default.createDirectory(at: configFixtures, withIntermediateDirectories: true)
        let url = configFixtures.appendingPathComponent("\(UUID().uuidString).conf")
        try? text.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    /// Control characters spelled out, because the two that matter here — the
    /// `^U` that clears the prompt and the `\r` that submits — are invisible in
    /// a failure message otherwise, and "expected: mdv, actual: mdv" is not a
    /// test result anybody can act on.
    private static func visible(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{15}", with: "^U ")
            .replacingOccurrences(of: "\u{03}", with: "^C")
            .replacingOccurrences(of: "\r", with: " CR")
    }

    /// A reader with `pid` in the foreground, where the viewer we watched start
    /// was `started`. The name deliberately never decides anything here: it is
    /// the half of this that a pipeline made unreliable, and a test that passed
    /// because the name happened to match would be proving the old rule.
    private static func plan(foreground: (pid_t, String)?, started: pid_t?) -> String {
        describe(Reader.plan(
            foreground: foreground.map { ForegroundProcess.Running(pid: $0.0, name: $0.1) },
            started: started
        ))
    }

    private static func describe(_ plan: Reader.Plan) -> String {
        switch plan {
        case .start: "start"
        case .swap: "swap"
        case let .busy(name): "busy \(name)"
        }
    }

    /// A matched rule named by what it runs, so a failure says which line of the
    /// list won rather than which struct.
    private static func describe(_ match: Reader.Match) -> String {
        switch match {
        case let .run(rule): rule.command
        case let .missing(tried): "missing \(tried.joined(separator: ", "))"
        case .unmatched: "<no rule>"
        }
    }

    private static func env(_ added: [String: String]) -> String {
        added.isEmpty ? "<none>" : added.keys.sorted().map { "\($0)=\(added[$0]!)" }.joined(separator: ", ")
    }

    private static func rename(_ decision: PaneOps.TabRename) -> String {
        switch decision {
        case .unchanged: "unchanged"
        case let .rename(slug): "rename \(slug)"
        case let .merge(slug): "merge \(slug)"
        }
    }

    /// "ephemeral" and "kept" rather than a bare flag, because the word the
    /// menu uses for the same state is "Keep".
    private static func newTab(_ decision: PaneOps.NewTab) -> String {
        switch decision {
        case let .create(name, ephemeral): "create \(name) \(ephemeral ? "ephemeral" : "kept")"
        case let .taken(name): "taken \(name)"
        }
    }

    private static func describe(_ changes: [PaneOps.LabelChange]) -> String {
        changes.map { change in
            var parts = [change.session + ":"]
            if let position = change.position { parts.append(position) }
            if let size = change.size { parts.append(String(format: "size=%.3f", size)) }
            return parts.joined(separator: " ").replacingOccurrences(of: ": ", with: ":")
        }.joined(separator: " | ")
    }

    /// Apply the edits the way the app does, so the tree can be checked rather
    /// than just the diff.
    private static func apply(_ changes: [PaneOps.LabelChange], to panes: [ZmxSession]) -> [ZmxSession] {
        var byName = Dictionary(uniqueKeysWithValues: panes.map { ($0.name, $0) })
        for change in changes {
            var labels = byName[change.session]?.labels ?? [:]
            if let position = change.position { labels["pos"] = position }
            if let size = change.size { labels["size"] = String(size) }
            byName[change.session] = ZmxSession(
                name: change.session, pid: "1", clients: 1, startDir: "/tmp", command: "zsh", labels: labels
            )
        }
        return byName.values.sorted { $0.name < $1.name }
    }

    private static func shapeOf(_ panes: [ZmxSession]) -> String {
        PaneTree.build(panes)?.debugShape ?? "<empty>"
    }

    private static func session(_ name: String) -> ZmxSession {
        ZmxSession(name: name, pid: "1", clients: 1, startDir: "/tmp", command: "zsh", labels: [:])
    }

    /// A directory listing as names in the order the tree would draw them.
    private static func names(_ specs: [(String, Bool)]) -> String {
        FileTree.sorted(specs.map { name, isDirectory in
            FileEntry(path: "/r/" + name, name: name, isDirectory: isDirectory)
        }).map(\.name).joined(separator: " ")
    }

    /// The visible tree in one line: name, depth, and what the disclosure is
    /// doing — `*` open, `…` open but still reading, `!` a directory that
    /// refuses to open because it links back into itself.
    private static func rowShape(_ rows: [FileRow]) -> String {
        rows.map { row in
            let mark = if row.isLoading { "…" }
            else if row.isExpanded { "*" }
            else if row.entry.isDirectory, !row.canExpand { "!" }
            else { "" }
            return "\(row.entry.name)\(row.depth)\(mark)"
        }.joined(separator: " ")
    }

    private static func iconAsset(command: String, dir: String = "/tmp") -> String {
        PaneIcon.asset(for: ZmxSession(
            name: "pane", pid: "1", clients: 1, startDir: dir, command: command, labels: [:]
        ))
    }

    private static func describe(_ fractions: [Double]?) -> String {
        guard let fractions else { return "<none>" }
        return fractions.map { String(format: "%.3f", $0) }.joined(separator: ", ")
    }

    private static func sessions(_ specs: [(String, String?, Double?)]) -> [ZmxSession] {
        specs.map { name, position, size in
            var labels: [String: String] = [:]
            if let position { labels["pos"] = position }
            if let size { labels["size"] = String(size) }
            return ZmxSession(
                name: name, pid: "1", clients: 1, startDir: "/tmp", command: "zsh", labels: labels
            )
        }
    }

    private static func shape(_ specs: [(String, String?, Double?)]) -> String {
        PaneTree.build(sessions(specs))?.debugShape ?? "<empty>"
    }

    private static func fractions(_ specs: [(String, String?, Double?)]) -> String {
        guard case let .split(_, children)? = PaneTree.build(sessions(specs)) else { return "<not a split>" }
        return children.map { String(format: "%.2f", $0.fraction) }.joined(separator: ", ")
    }
}

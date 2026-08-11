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

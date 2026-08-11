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

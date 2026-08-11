import Combine
import Foundation

/// One live zmx session. This is the whole app model — there is no state file,
/// no tab database. Everything below is either reported by the daemon or stored
/// as a label on the session itself, so `zsm`, a shell script, and this app can
/// never disagree about what exists.
struct ZmxSession: Identifiable, Equatable {
    let name: String
    let pid: String
    let clients: Int
    let startDir: String
    let command: String
    let labels: [String: String]

    var id: String { name }

    /// Which tab this pane belongs to. Defaults to the part of the name before
    /// the first dot, so `spike-dev-1.shell` groups under `spike-dev-1` with no
    /// label set at all; an orchestrator building a team wall sets `tab=spike`
    /// on panes from several different agents.
    var tab: String { labels["tab"] ?? defaultTab }

    /// Where this pane lands with no `tab` label at all. Worth naming
    /// separately from `tab` because clearing the label is not the same as
    /// making a pane disappear — every session belongs to some tab, always, so
    /// a pane taken off a wall falls back here rather than off the screen.
    var defaultTab: String {
        name.split(separator: ".", maxSplits: 1).first.map(String.init) ?? name
    }

    /// The labels that say where a pane sits, as opposed to what it is. Named
    /// once so `removeFromTab` and the test that checks where a pane lands
    /// cannot drift apart.
    static let placementLabels = ["pos", "size", "tab"]

    /// Whether taking this pane out of its tab would actually move it.
    ///
    /// A pane that is already sitting unplaced in its own default tab has
    /// nowhere to be removed to, and offering the command anyway would be a
    /// menu item that visibly does nothing.
    var canLeaveTab: Bool { tab != defaultTab || position != nil }

    /// The `.part` suffix, or the whole name for a tab's primary pane.
    var part: String? {
        let pieces = name.split(separator: ".", maxSplits: 1)
        return pieces.count > 1 ? String(pieces[1]) : nil
    }

    /// Position in the tab's split tree, e.g. `v0.h1.v2`. Absent means the pane
    /// is alone in its tab.
    var position: String? { labels["pos"] }

    /// Share of the whole tab, 0...1 — not of the parent split. See
    /// `PaneNode.declaredShare`. Absent means "split whatever is left over".
    var sizeFraction: Double? { labels["size"].flatMap(Double.init) }

    /// `waiting` (wants you) or `failed` (went wrong); absent means resting.
    var state: String? { labels["state"] }

    var isEphemeral: Bool { labels["ephemeral"] == "1" }

    /// A human-chosen label. zmx cannot rename a session — the name is the
    /// socket path — so this is how a pane gets called something else.
    var title: String? { labels["title"] }

    var displayDirectory: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return startDir.hasPrefix(home) ? "~" + startDir.dropFirst(home.count) : startDir
    }
}

enum Zmx {
    /// The app never inherits a login shell's PATH, so find the binary rather
    /// than trusting `zmx` to resolve.
    static let executable: String = {
        let candidates = [
            ProcessInfo.processInfo.environment["ZMX_BIN"],
            "/opt/homebrew/bin/zmx",
            "/usr/local/bin/zmx",
        ].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "zmx"
    }()

    @discardableResult
    static func run(_ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return ""
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// `zmx list` already carries labels inline, so one call yields the entire
    /// model — sessions and their placement together.
    static func list() -> [ZmxSession] {
        let reserved: Set<String> = ["name", "session_name", "pid", "clients", "created", "start_dir", "started_in", "cmd"]

        return run(["list"]).split(separator: "\n").compactMap { rawLine in
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("→") { line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces) }
            guard !line.isEmpty else { return nil }

            var fields: [String: String] = [:]
            for field in line.split(separator: "\t") {
                guard let separator = field.firstIndex(of: "=") else { continue }
                fields[String(field[field.startIndex ..< separator])] = String(field[field.index(after: separator)...])
            }

            guard let name = fields["name"] ?? fields["session_name"] else { return nil }
            return ZmxSession(
                name: name,
                pid: fields["pid"] ?? "",
                clients: Int(fields["clients"] ?? "") ?? 0,
                startDir: fields["start_dir"] ?? fields["started_in"] ?? "",
                command: fields["cmd"] ?? "",
                labels: fields.filter { !reserved.contains($0.key) }
            )
        }
    }
}

/// Keeps the model current. Session lifecycle arrives as socket-directory
/// changes; label edits have no push channel, so they are polled — cheap, since
/// one `zmx list` returns everything.
@MainActor
final class ZmxRegistry: ObservableObject {
    @Published private(set) var sessions: [ZmxSession] = []

    private var directorySource: DispatchSourceFileSystemObject?
    private var pollTimer: Timer?

    init() {
        refresh()
        watchSocketDirectory()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    deinit {
        directorySource?.cancel()
        pollTimer?.invalidate()
    }

    func refresh() {
        var listed = Zmx.list().sorted { $0.name < $1.name }

        // zmx reports no `cmd`, so fill it in from each session's process tree.
        // Without this every pane looks like a bare shell and the icon rule has
        // only the working directory to go on.
        let running = ForegroundProcess.resolve(sessionPIDs: listed.map(\.pid))
        listed = listed.map { session in
            guard session.command.isEmpty, let found = running[session.pid] else { return session }
            return ZmxSession(
                name: session.name, pid: session.pid, clients: session.clients,
                startDir: session.startDir, command: found, labels: session.labels
            )
        }
        Log.debug("registry refresh: \(listed.count) sessions via \(Zmx.executable)")
        if listed != sessions { sessions = listed }
    }

    /// Sessions grouped into tabs, tabs sorted by name, panes by position.
    var tabs: [(name: String, panes: [ZmxSession])] {
        Dictionary(grouping: sessions, by: \.tab)
            .map { (name: $0.key, panes: $0.value.sorted { ($0.position ?? $0.name) < ($1.position ?? $1.name) }) }
            .sorted { $0.name < $1.name }
    }

    private func watchSocketDirectory() {
        let path = ZmxClient.socketDirectory().path
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in self?.refresh() }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        directorySource = source
    }
}

extension Zmx {
    /// Create a session running a plain login shell, with nobody attached.
    ///
    /// `zmx run` looks like the obvious way to do this and is wrong: it is task
    /// mode, so it echoes the command and appends a `ZMX_TASK_COMPLETED:$?`
    /// marker, and it runs under bash rather than the user's shell. The pane
    /// opens showing its own plumbing.
    ///
    /// `zmx attach` creates the session with a login `$SHELL` and no wrapper.
    /// Pointing stdin at /dev/null makes the client read EOF and detach the
    /// instant the daemon exists, which leaves exactly the state a pane wants
    /// to attach to: running, clean, nobody watching.
    static func createSession(named name: String, in directory: String?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["attach", name]
        if let directory, FileManager.default.fileExists(atPath: directory) {
            process.currentDirectoryURL = URL(fileURLWithPath: directory)
        }
        // The daemon inherits this process's environment, so anything set here
        // lands in the session's shell and every child of it.
        //
        // Be clear what it can mean: only sessions *created* by this app get
        // it. One made in a terminal and later shown in a pane will not, so
        // `ZMXTERM` answers "did zmxterm make me", never "am I on screen".
        // `ZMX_SESSION`, which zmx sets for every session however it was made,
        // is the variable worth branching on.
        var environment = ProcessInfo.processInfo.environment
        environment["ZMXTERM"] = "1"
        environment["ZMXTERM_VERSION"] = Zmx.appVersion
        environment["TERM"] = Zmx.terminalType
        environment["COLORTERM"] = "truecolor"
        // The convention Terminal.app, iTerm and Ghostty all follow, so shell
        // configs that branch on the host have something to branch on.
        environment["TERM_PROGRAM"] = "zmxterm"
        environment["TERM_PROGRAM_VERSION"] = Zmx.appVersion
        process.environment = environment

        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    static let appVersion = "0.7.7"

    /// What to tell the shell it is talking to.
    ///
    /// A GUI app inherits no `TERM`, so a session it creates gets an empty one
    /// and every curses program in it misbehaves — no colour, broken `clear`,
    /// vim refusing to start.
    ///
    /// `xterm-ghostty` is the honest answer, because libghostty is what draws
    /// the pane. But naming a terminfo entry that the machine cannot resolve is
    /// worse than under-claiming: programs fail outright rather than degrade.
    /// The entry ships with Ghostty, so probe for it once and fall back to the
    /// universally present `xterm-256color` when it isn't there.
    static let terminalType: String = {
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/usr/bin/infocmp")
        probe.arguments = ["xterm-ghostty"]
        probe.standardOutput = FileHandle.nullDevice
        probe.standardError = FileHandle.nullDevice
        do {
            try probe.run()
            probe.waitUntilExit()
            if probe.terminationStatus == 0 { return "xterm-ghostty" }
        } catch {}
        return "xterm-256color"
    }()

    static func apply(_ changes: [PaneOps.LabelChange]) {
        for change in changes {
            var pairs: [String] = []
            if let position = change.position { pairs.append("pos=\(position)") }
            if let size = change.size { pairs.append(String(format: "size=%.3f", size)) }
            if let tab = change.tab { pairs.append("tab=\(tab)") }
            if change.ephemeral { pairs.append("ephemeral=1") }
            guard !pairs.isEmpty else { continue }
            run(["set", change.session] + pairs)
        }
    }
}

extension ZmxRegistry {
    /// Split the focused pane, returning the new pane's name.
    ///
    /// Creating the session first and labelling it second means a pane that
    /// exists but hasn't been placed yet is briefly visible to `zsm` — which is
    /// honest: it does exist. The reverse order would label a session that
    /// isn't there.
    @discardableResult
    func split(pane focused: String, axis: SplitAxis) -> String? {
        guard let pane = sessions.first(where: { $0.name == focused }) else { return nil }
        let tab = pane.tab
        let panes = sessions.filter { $0.tab == tab }
        let name = SessionNames.nextPane(in: tab, avoiding: Set(sessions.map(\.name)))

        Zmx.createSession(named: name, in: pane.startDir)
        Zmx.apply(PaneOps.split(panes: panes, focused: focused, axis: axis, newSession: name, tab: tab))
        refresh()
        return name
    }

    /// A new tab is a session that is its own tab. No dialog: the name is a
    /// placeholder until someone cares enough to change it, and an unnamed pane
    /// is `ephemeral` so it gets reaped rather than accumulating.
    @discardableResult
    func newTab(near: ZmxSession?) -> String? {
        let name = SessionNames.nextTab(avoiding: Set(sessions.map(\.tab)))
        Zmx.createSession(named: name, in: near?.startDir ?? FileManager.default.homeDirectoryForCurrentUser.path)
        Zmx.apply([PaneOps.LabelChange(session: name, position: nil, size: nil, tab: name, ephemeral: true)])
        refresh()
        return name
    }
}

extension Zmx {
    /// Labels accept only `[A-Za-z0-9._-]`, so anything a human types has to be
    /// folded into that before it can be stored. Spaces become dashes rather
    /// than vanishing, so "my project" stays two words to read.
    static func slug(_ raw: String) -> String {
        let folded = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "-")
        let kept = folded.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0)
        }
        return String(String.UnicodeScalarView(kept))
    }
}

extension ZmxRegistry {
    func kill(_ session: String) {
        Zmx.run(["kill", session, "--force"])
        refresh()
    }

    /// A pane's name is its socket path and can never change, so a rename is a
    /// `title` label the display prefers. The name stays the stable id.
    func setTitle(_ title: String, on session: String) {
        let slug = Zmx.slug(title)
        Zmx.run(["set", session, slug.isEmpty ? "title=" : "title=\(slug)"])
        refresh()
    }

    /// A tab, unlike a pane, really can be renamed: its identity is the `tab`
    /// label, so renaming is rewriting that label across its panes.
    func renameTab(_ tab: String, to newName: String) {
        let slug = Zmx.slug(newName)
        guard !slug.isEmpty, slug != tab else { return }
        for pane in sessions where pane.tab == tab {
            Zmx.run(["set", pane.name, "tab=\(slug)"])
        }
        refresh()
    }

    /// Take a pane off its tab without touching what runs in it.
    ///
    /// This is the gesture the model was built for and the one the UI was
    /// missing: a pane is a *view* of a session, so there has to be a way to
    /// stop viewing it that isn't killing it. Clearing the placement labels is
    /// the whole implementation — the same `zmx set <name> pos= size= tab=` an
    /// agent would run, which is the test for whether a feature belongs here.
    ///
    /// `size` goes with the other two on purpose. A share is a share *of a
    /// tab* (see `PaneNode.declaredShare`), so a pane that has left the tab is
    /// carrying a number that no longer refers to anything.
    ///
    /// Note what this does not do: it cannot make a pane vanish. `tab` falls
    /// back to `defaultTab` when the label is absent, so the pane reappears
    /// under the part of its name before the first dot — off the wall it was
    /// gathered onto, still running, still findable in the sidebar. That is
    /// the honest behaviour to promise, and it is why the menu says "Remove
    /// from Tab" rather than "Hide".
    func removeFromTab(_ session: String) {
        Zmx.run(["set", session] + ZmxSession.placementLabels.map { "\($0)=" })
        refresh()
    }

    /// Naming something is what promotes it out of being disposable, so the
    /// menu says "Keep" rather than talking about labels.
    func setEphemeral(_ ephemeral: Bool, on session: String) {
        Zmx.run(["set", session, ephemeral ? "ephemeral=1" : "ephemeral="])
        refresh()
    }
}

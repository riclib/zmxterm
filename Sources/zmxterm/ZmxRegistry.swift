import Combine
import Foundation
import GhosttyKit

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

    /// When the daemon says this session came into being. `zmx list` reports it
    /// as a unix timestamp and nothing used to read it, so it was dropped along
    /// with the other daemon-owned fields. `ReapPolicy` needs it: age since
    /// creation is the only clock the app has for "has anyone cared about this
    /// pane lately", so the field has to survive the parse.
    ///
    /// Optional because a missing or unparseable `created` must not read as
    /// "created at the epoch, therefore ancient, therefore disposable". Nil
    /// means unknown, and the reaper treats unknown as too young to touch.
    let createdAt: Date?

    /// Written by hand rather than left to the memberwise initialiser so that
    /// `createdAt` can default, and every existing construction site — the
    /// tests, the command back-fill below — keeps compiling unchanged.
    init(
        name: String,
        pid: String,
        clients: Int,
        startDir: String,
        command: String,
        labels: [String: String],
        createdAt: Date? = nil
    ) {
        self.name = name
        self.pid = pid
        self.clients = clients
        self.startDir = startDir
        self.command = command
        self.labels = labels
        self.createdAt = createdAt
    }

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

    /// The pane documents open in. A bare flag rather than anything describing
    /// the document, because the path is in argv and a path could not go in a
    /// label anyway — the charset has no slash. See `Reader`.
    var isReader: Bool { labels["reader"] == "1" }

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
        // `ended` and `exit_code` appear only on a session that has completed a
        // `zmx run` task, and they arrive in the same tab-separated stream as
        // the labels, so without naming them here every finished task would
        // invent two labels nobody set. The app reads those two over `.info`
        // instead — see `ZmxInfo` — where they are typed fields rather than
        // text that shares a namespace with whatever a human chose to call a
        // label.
        let reserved: Set<String> = [
            "name", "session_name", "pid", "clients", "created",
            "start_dir", "started_in", "cmd", "ended", "exit_code",
        ]

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
                labels: fields.filter { !reserved.contains($0.key) },
                // Still reserved, so it stays out of `labels` — it is the
                // daemon's field, not something anyone can set — but no longer
                // discarded on the way past.
                createdAt: Double(fields["created"] ?? "").map { Date(timeIntervalSince1970: $0) }
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
    /// Tasks ride along on the same poll, over a socket of their own, because
    /// `zmx list` is the wrong place to read them from. See `ZmxTaskWatcher`.
    private let taskWatcher = ZmxTaskWatcher()

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
                startDir: session.startDir, command: found, labels: session.labels,
                createdAt: session.createdAt
            )
        }
        Log.debug("registry refresh: \(listed.count) sessions via \(Zmx.executable)")
        if listed != sessions { sessions = listed }

        // Deliberately after the assignment, so the watcher judges against the
        // labels this refresh just read rather than the previous round's.
        taskWatcher.poll(listed) { [weak self] in self?.refresh() }
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
    /// The environment to hand a `zmx` client this app spawns, given the one
    /// the app itself inherited.
    ///
    /// `ZMX_SESSION` has to go, and it is load-bearing rather than tidy-up.
    /// `zmx attach` run with it set creates nothing: the client reads it,
    /// concludes it is already inside a session, and sends `.SwitchSession` to
    /// that daemon instead — exit 0, no new session, no error. Launch zmxterm
    /// from a terminal that is itself in a pane, which is the ordinary way to
    /// launch it while developing, and every Split and every new tab silently
    /// does nothing. That is issue #16. Worse, the switch is a harmless no-op
    /// only while the target name happens to be free; aimed at a name that
    /// exists it would yank whichever pane the app was launched from over to
    /// some other session.
    ///
    /// Nothing is lost by removing it, because zmx injects `ZMX_SESSION` into
    /// every session it creates. The new pane's shell still reports its own
    /// name; what stops is the *parent's* name leaking into the child.
    ///
    /// Nothing else is stripped, and that is a decision rather than an
    /// oversight. zmx 0.7.0 reads `ZMX_DIR`, `ZMX_DIR_MODE`, `ZMX_LOG_MODE`,
    /// `ZMX_SESSION_PREFIX` and `ZMX_SESSION` (see `zmx help`), and this app
    /// reads `ZMX_SOCKET_DIR` and `ZMX_BIN` of its own. `ZMX_DIR` has to be
    /// inherited because `Zmx.run` passes it through to `list` and `set`, so
    /// dropping it from creates alone would put new sessions in a socket
    /// directory the app does not enumerate; `ZMX_DIR_MODE` and `ZMX_LOG_MODE`
    /// only choose permissions and express a preference worth honouring. The
    /// app's own two matter to the created shell, which should be able to
    /// launch zmxterm again exactly as this one was launched.
    ///
    /// `ZMX_SESSION_PREFIX` is the near miss, and it is left alone on purpose.
    /// It genuinely does change what `zmx attach <name>` creates — measured
    /// against zmx 0.7.0: with it set, `attach probe` yields `<prefix>probe` —
    /// so it is the same class of trap. But `zmx set` applies the prefix too,
    /// while `zmx list` reports real, unprefixed names. Stripping it *here
    /// alone* would therefore be a regression rather than a fix: the create
    /// would land on the bare name while the `zmx set` that places the new
    /// pane, sent through `Zmx.run` with the prefix still in the app's own
    /// environment, would aim at a session that does not exist, and the pane
    /// would arrive unplaced. Doing it properly means stripping it from
    /// `Zmx.run` as well, which reaches `kill` and `set` on sessions this app
    /// never created and is a wider change than this bug justifies. Nobody sets
    /// it here today. Whoever does should fix both ends at once, or neither.
    static func clientEnvironment(inheriting environment: [String: String]) -> [String: String] {
        var environment = environment
        environment["ZMX_SESSION"] = nil
        return environment
    }

    /// What a session created here is told about the terminal it is running in.
    ///
    /// The daemon inherits this process's environment, so anything set here
    /// lands in the session's shell and every child of it.
    ///
    /// Be clear what it can mean: only sessions *created* by this app get it.
    /// One made in a terminal and later shown in a pane will not, so `ZMXTERM`
    /// answers "did zmxterm make me", never "am I on screen". `ZMX_SESSION`,
    /// which zmx sets for every session however it was made, is the variable
    /// worth branching on.
    ///
    /// What is removed on the way in matters as much as what is added — see
    /// `clientEnvironment(inheriting:)`, which is the only reason a create
    /// creates anything at all when the app was launched from a pane.
    ///
    /// `terminalType` and `emulatorVersion` are parameters rather than direct
    /// reads of `Zmx.terminalType` and `Zmx.emulatorVersion` because those probe
    /// `infocmp` and libghostty on first use, and a test should not need a
    /// terminfo database or a linked emulator to ask what this function does.
    static func sessionEnvironment(
        inheriting inherited: [String: String],
        terminalType: String,
        emulatorVersion: String
    ) -> [String: String] {
        var environment = clientEnvironment(inheriting: inherited)
        environment["ZMXTERM"] = "1"
        environment["ZMXTERM_VERSION"] = Zmx.appVersion
        environment["TERM"] = terminalType
        environment["COLORTERM"] = "truecolor"
        // The convention Terminal.app, iTerm and Ghostty all follow, so shell
        // configs that branch on the host have something to branch on.
        //
        // It says `ghostty`, not `zmxterm`, and that reads like a lie until you
        // know what the variable names. `TERM_PROGRAM` names the *emulator*, and
        // ours is libghostty — the same code Ghostty ships, drawing the same
        // cells with the same capabilities. It is the same claim `TERM` makes on
        // the line above, for the same reason: the thing that describes what
        // this pane can do is Ghostty's.
        //
        // The claim is worth making because it is backed. Tools detect the kitty
        // graphics protocol by program name — `mdv` refuses interactive mode
        // outright unless `TERM_PROGRAM` is `ghostty` or `TERM` contains
        // `kitty` — and graphics do survive the whole trip here: emitted by the
        // program, carried through zmx's terminal emulation, drawn by our
        // surface. Under `zmxterm` a viewer that works is turned away on its
        // name; under `ghostty` it runs. Capability-by-program-name is wrong and
        // common, and not ours to fix in every tool.
        //
        // What it costs is the "which app am I in" signal, which is why
        // `ZMXTERM` and `ZMXTERM_VERSION` above stay: anything wanting to know
        // it is specifically zmxterm reads those, with the caveat above about
        // what they can honestly answer. Note which version goes where —
        // `ZMXTERM_VERSION` is the app's, and the pair below is the emulator's.
        // Crossing them is the bug described on `Zmx.emulatorVersion`.
        environment["TERM_PROGRAM"] = "ghostty"
        // Dropped rather than emitted empty when the emulator has no version to
        // give: `TERM_PROGRAM_VERSION=` is a tool's problem to parse, and unset
        // is the state every tool already handles.
        environment["TERM_PROGRAM_VERSION"] = emulatorVersion.isEmpty ? nil : emulatorVersion
        return environment
    }

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
        var environment = sessionEnvironment(
            inheriting: ProcessInfo.processInfo.environment,
            terminalType: Zmx.terminalType,
            emulatorVersion: Zmx.emulatorVersion
        )

        // Ghostty's shell integration, so the shell reports its working
        // directory and marks its prompts instead of the pane having to infer
        // both from a byte stream. Read through `getenv` rather than the
        // snapshot above because `GhosttyResources.locate()` sets this with
        // `setenv` during startup, and a cached snapshot would miss it.
        if let raw = getenv("GHOSTTY_RESOURCES_DIR") {
            let added = ShellIntegration.environment(
                shell: ShellIntegration.loginShell(inherited: environment),
                resources: String(cString: raw),
                inherited: environment
            )
            for (key, value) in added { environment[key] = value }
            if !added.isEmpty { Log.debug("shell integration: \(added.keys.sorted().joined(separator: ", "))") }
        }

        process.environment = environment

        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    static let appVersion = "0.12.1"

    /// The version of the emulator this app claims to be, asked of the emulator
    /// itself.
    ///
    /// `TERM_PROGRAM=ghostty` and `TERM_PROGRAM_VERSION` are read as a pair, so
    /// pairing the name with `appVersion` would say "Ghostty 0.8.0" — a real
    /// Ghostty, and a pre-1.0 one. That is the same failure this app's naming
    /// was changed to avoid, only later in the conversation: a tool that
    /// name-checks its way past the first gate and is then turned back by a
    /// version gate, for a capability we demonstrably have.
    ///
    /// So it is `ghostty_info()`, not a constant tracking `Package.resolved`.
    /// Both are truthful the day they are written; only this one is still
    /// truthful after a dependency bump, because it is the linked library
    /// answering rather than a number somebody has to remember to change. It
    /// reports the full string including any pre-release suffix — trimming that
    /// to look tidier would be inventing a precision the build does not have.
    static let emulatorVersion: String = {
        let info = ghostty_info()
        guard info.version_len > 0,
              let version = String(
                  data: Data(bytes: info.version, count: Int(info.version_len)), encoding: .utf8
              ), !version.isEmpty
        else {
            // Nothing sensible to claim. Say nothing rather than guess: the
            // variable is dropped downstream, which reads as "unknown" instead
            // of as a version that was never true.
            Log.debug("ghostty_info reported no version")
            return ""
        }
        return version
    }()

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

    /// The placeholder a New Tab dialog opens with: the first Guide name not
    /// already spoken for.
    ///
    /// Avoiding `occupiedTabNames` rather than the `tab` labels alone is what
    /// lets the dialog promise that its own proposal never collides. A session
    /// gathered onto someone else's wall holds its name without holding a tab,
    /// and proposing that name would send the create at it.
    func proposedTabName() -> String {
        SessionNames.nextTab(avoiding: PaneOps.occupiedTabNames(among: sessions))
    }

    /// What the New Tab dialog would do with what has been typed into it.
    func planNewTab(typed: String, proposed: String) -> PaneOps.NewTab {
        PaneOps.newTab(typed: typed, proposed: proposed, among: sessions)
    }

    /// A new tab is a session that is its own tab, created under a name that
    /// has already been agreed.
    ///
    /// It used to be created silently under a placeholder, on the argument that
    /// the name was provisional until someone cared enough to change it. That
    /// argument no longer holds, from both ends. `ReapPolicy` reads `ephemeral`
    /// as "nobody ever named this", so writing it unconditionally was the app
    /// answering a question about the user on the user's behalf — and the only
    /// moment the answer is actually available is the moment of creation, which
    /// is why it arrives here as a parameter rather than being decided here.
    /// And the name is not provisional at all: it is the session's socket path,
    /// so it has to have been folded and checked against what exists before
    /// this runs, or the create silently targets a session that is already
    /// there. Both of those decisions are `PaneOps.newTab`'s; this only writes.
    @discardableResult
    func newTab(named name: String, ephemeral: Bool, near: ZmxSession?) -> String? {
        Zmx.createSession(named: name, in: near?.startDir ?? FileManager.default.homeDirectoryForCurrentUser.path)
        Zmx.apply([PaneOps.LabelChange(session: name, position: nil, size: nil, tab: name, ephemeral: ephemeral)])
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
    ///
    /// Which is also why it cannot just be done. The same write, aimed at a
    /// name that is already taken, silently merges two tabs — see
    /// `PaneOps.TabRename`. So the decision comes back as data and the caller
    /// handles the merge case by asking.
    func planRename(of tab: String, to newName: String) -> PaneOps.TabRename {
        PaneOps.renameTab(tab, to: newName, among: sessions)
    }

    /// Move every pane of `tab` under the label `slug`.
    ///
    /// Rename and merge are the identical write — what separates them is only
    /// whether the destination was in use and whether anyone was asked — so
    /// they share one implementation rather than two that could drift.
    func writeTab(_ slug: String, over tab: String) {
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

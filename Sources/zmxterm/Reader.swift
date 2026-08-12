import Foundation

/// The pane you keep documents in.
///
/// A reader is **a shell session running a viewer**, marked `reader=1` — not a
/// session whose process *is* the viewer, and not a native panel. That
/// distinction is the whole feature. With a shell underneath, the viewer can be
/// stopped and started again on a different file while the pane keeps its name,
/// position, size, scrollback and labels; a session whose process was the viewer
/// would have to be killed and recreated for every document, losing all of it.
///
/// It also keeps the one rule in `CLAUDE.md`. A reader is a zmx session like any
/// other, so `zsm` sees it, it survives the app quitting, and it restores itself
/// without the app remembering anything. The label is a bare flag, which fits
/// zmx's `[A-Za-z0-9._-]` charset — the path, which could never live in a label,
/// lives in argv where a path belongs.
///
/// Everything here is a pure function of (what is running, configuration, path)
/// so `--selftest` can settle the interesting arguments — what gets typed, when
/// the viewer is quit first, when the pane is refused — without a daemon, a
/// window, or a viewer installed.
enum Reader {
    // MARK: - Configuration

    /// The viewer is configuration, not a hardcode: `glow`, `presenterm` or
    /// whatever comes next has to be reachable without a build.
    ///
    ///     defaults write land.liberato.zmxterm readerCommand "glow -p"
    ///     defaults write land.liberato.zmxterm readerQuitKey q
    ///
    /// There is deliberately no UI for it. The default is the viewer this was
    /// designed against, and a preferences window for two strings would be more
    /// app than the app.
    struct Configuration: Equatable {
        /// Everything before the path. Not a path template: the path is
        /// appended, quoted, because a viewer takes its file last.
        var command: String

        /// What makes the viewer exit. `q` quits `mdv`, `glow` and `less`
        /// alike. Empty means "this one has no quit key" — then the swap goes
        /// straight to the signal below rather than typing a letter into
        /// something that will only display it.
        var quitKey: String

        static let `default` = Configuration(command: "mdv --watch", quitKey: "q")

        /// The binary the command runs, which is what `ps` will report and what
        /// has to exist on the shell's PATH.
        var viewer: String { Reader.viewer(of: command) }
    }

    static let commandDefaultsKey = "readerCommand"
    static let quitKeyDefaultsKey = "readerQuitKey"

    static var configuration: Configuration {
        configuration(
            command: UserDefaults.standard.string(forKey: commandDefaultsKey),
            quitKey: UserDefaults.standard.string(forKey: quitKeyDefaultsKey)
        )
    }

    /// Read as data so the defaults can be tested without writing any.
    ///
    /// An unset key and a key set to whitespace both mean "no preference" for
    /// the command, because a blank command names no viewer and there is
    /// nothing useful to do with it. `quitKey` is different: blank is a real
    /// answer there, and only an absent key falls back.
    static func configuration(command: String?, quitKey: String?) -> Configuration {
        let trimmed = command?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Configuration(
            command: trimmed.isEmpty ? Configuration.default.command : trimmed,
            quitKey: quitKey ?? Configuration.default.quitKey
        )
    }

    /// The binary in a command line, skipping leading `NAME=value` assignments.
    ///
    /// The assignments are not hypothetical: `TERM=xterm-kitty mdv --watch` is
    /// the documented workaround for #22, so somebody will configure it. Taking
    /// the first word blindly would name the viewer `TERM=xterm-kitty`, and then
    /// `plan` would compare that to what `ps` reports, conclude a stranger was
    /// running in the reader, and refuse to open anything.
    static func viewer(of command: String) -> String {
        for word in command.split(separator: " ", omittingEmptySubsequences: true) {
            // An assignment is `NAME=…` with nothing path-like before the `=`.
            if let equals = word.firstIndex(of: "="), !word[..<equals].contains("/") { continue }
            return (String(word) as NSString).lastPathComponent
        }
        return ""
    }

    // MARK: - Which pane

    /// The reader of one tab, if it has one.
    ///
    /// Scoped to a tab rather than to the whole machine, and that is the useful
    /// scope: a document opened from a file tree belongs beside the pane it was
    /// opened from, and sending it to a reader in a tab you are not looking at
    /// would be a document that opens nowhere. A tab with two panes marked by
    /// hand resolves to the first in the order the registry sorts them, which is
    /// stable, rather than to whichever `zmx list` happened to report first.
    static func pane(among panes: [ZmxSession], tab: String) -> ZmxSession? {
        panes.first { $0.tab == tab && $0.isReader }
    }

    // MARK: - What gets typed

    /// The command line for a document. The path is quoted rather than escaped
    /// because it is going into a shell — `FileTree.shellQuoted` is the same
    /// rule the file tree inserts paths with, so a path with a space in it
    /// cannot arrive as two different strings depending on which gesture sent
    /// it. Absolute, not relative: the reader's shell is not necessarily sitting
    /// in the directory the tree is rooted at.
    static func commandLine(_ configuration: Configuration, opening path: String) -> String {
        configuration.command + " " + FileTree.shellQuoted(path)
    }

    /// The bytes that actually reach the pty, which is the command line with a
    /// `^U` in front and a carriage return behind.
    ///
    /// The return is the one place in this app where a trailing newline is
    /// wanted — the file tree inserts a path for a person to finish, this runs a
    /// viewer — and `\r` rather than `\n` because that is what the Return key
    /// sends.
    ///
    /// `^U` kills whatever is on the shell's line first, and it is not
    /// tidiness. A viewer that ignored its quit key gets signalled, and the `q`
    /// it ignored has been echoed onto the prompt underneath it by then;
    /// without the kill the next command arrives as `qmdv --watch …`. It is
    /// `^U` rather than `^C` because SIGINT flushes the tty's input queue, so a
    /// `^C` sent in the same write would take the command with it.
    static func keystrokes(_ configuration: Configuration, opening path: String) -> String {
        "\u{15}" + commandLine(configuration, opening: path) + "\r"
    }

    // MARK: - What opening a document requires

    /// Whether the viewer has to be stopped before the next one can start, given
    /// what is running in the reader now.
    enum Plan: Equatable {
        /// Nothing but the login shell: type the command.
        case start
        /// The viewer is up on another document: quit it, then type.
        case swap
        /// Something else entirely is running in there. Refused, with the name.
        case busy(String)
    }

    /// A pane marked `reader=1` is still a shell somebody can use, and `vim` or
    /// a build running in it is not a viewer to be quit and typed over. So an
    /// unrecognised foreground process refuses rather than guessing — the only
    /// process this will ever send a quit key to is the one it was configured to
    /// start.
    static func plan(foreground: String?, configuration: Configuration) -> Plan {
        guard let foreground, !foreground.isEmpty else { return .start }
        let viewer = configuration.viewer
        guard !viewer.isEmpty else { return .busy(foreground) }
        return foreground.caseInsensitiveCompare(viewer) == .orderedSame ? .swap : .busy(foreground)
    }

    // MARK: - Is the viewer even there

    /// Asked of the *login shell*, because that is the PATH the pane will have
    /// and it is not this app's.
    ///
    /// A GUI process inherits no login environment — the same fact that makes
    /// `Zmx.executable` a list of candidate paths — so `mdv` installed in
    /// `~/.local/bin` is invisible to us and perfectly visible to the session.
    /// Asking the shell is the only answer that matches what will happen.
    /// Measured at ~35ms with a `zsh -lc`, which is why it can sit on the main
    /// thread inside a menu action rather than needing to be hoisted off it.
    static func isInstalled(_ configuration: Configuration,
                            shell: String = ShellIntegration.loginShell()) -> Bool
    {
        let viewer = configuration.viewer
        guard !viewer.isEmpty else { return false }
        // A configured path is checkable without asking anybody.
        if viewer.contains("/") { return FileManager.default.isExecutableFile(atPath: viewer) }
        let found = ForegroundProcess.shell(shell, ["-lc", "command -v -- " + FileTree.shellQuoted(viewer)])
        return !found.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Timings

    /// How long a viewer gets to act on its own quit key before it is signalled.
    /// Measured: `mdv` is gone in well under half of this.
    static let quitGrace: TimeInterval = 0.5
    /// And how long after a signal before the shell is typed into.
    static let signalGrace: TimeInterval = 0.4
    /// How long a freshly created session gets before its shell is typed into.
    /// The daemon exists by the time `createSession` returns — it waits for the
    /// client to exit — but the login shell inside it is still starting.
    static let startupGrace: TimeInterval = 0.6

    // MARK: - What happened

    /// The result of asking for a document, in the caller's terms rather than
    /// in labels, so the panel that asked can say why nothing opened.
    enum Outcome: Equatable {
        case opened(pane: String)
        case busy(pane: String, running: String)
        case missingViewer(String)
        /// No pane to split, so there is nowhere to put a reader.
        case noPane

        /// Nil when it worked. A sentence otherwise, naming the thing to fix.
        var problem: String? {
            switch self {
            case .opened:
                nil
            case let .busy(pane, running):
                "\(pane) is running \(running). Quit it first, or open the document in another reader."
            case let .missingViewer(viewer):
                """
                \(viewer) is not installed, or not on the login shell's PATH. \
                Install it, or set another viewer with \
                `defaults write land.liberato.zmxterm readerCommand "glow -p"`.
                """
            case .noPane:
                "There is no pane here to open a reader beside."
            }
        }
    }
}

// MARK: - Opening a document

@MainActor
extension ZmxRegistry {
    /// Open `path` in `tab`'s reader, making one if the tab has none.
    ///
    /// "Stable panel" is the whole design: a second document replaces what the
    /// reader is showing rather than building a second reader, so this prefers
    /// an existing pane over creating one and only ever splits when there is
    /// nothing marked `reader=1` in the tab.
    ///
    /// Returns immediately with what it decided. The typing that follows is
    /// spread over a few hundred milliseconds — a viewer needs a beat to act on
    /// its quit key, a new session needs one to start its shell — and none of it
    /// changes the answer to "did this open, and if not why not".
    @discardableResult
    func openInReader(
        path: String,
        tab: String,
        near focused: String?,
        store: PaneStore,
        configuration: Reader.Configuration = Reader.configuration
    ) -> Reader.Outcome {
        let keystrokes = Reader.keystrokes(configuration, opening: path)

        if let reader = Reader.pane(among: sessions, tab: tab) {
            // Resolved now rather than read off the session's `command`, which
            // the registry fills in on a two-second poll: between the poll and
            // the click, the viewer may have been quit by hand.
            let running = ForegroundProcess.running(sessionPID: reader.pid)
            switch Reader.plan(foreground: running?.name, configuration: configuration) {
            case let .busy(name):
                Log.debug("reader \(reader.name): refusing, \(name) is running")
                return .busy(pane: reader.name, running: name)

            case .start:
                send(keystrokes, to: reader.name, store: store)
                return .opened(pane: reader.name)

            case .swap:
                if !configuration.quitKey.isEmpty {
                    send(configuration.quitKey, to: reader.name, store: store)
                }
                // The fallback the design asked for: a viewer that ignores its
                // own quit key must not leave the pane wedged. Only the process
                // we watched start is signalled — if the pid changed, the
                // viewer did exit and something else is there now, and that is
                // not ours to kill.
                DispatchQueue.main.asyncAfter(deadline: .now() + Reader.quitGrace) { [weak self] in
                    guard let self else { return }
                    let stubborn = ForegroundProcess.running(sessionPID: reader.pid)
                    guard let stubborn, stubborn.pid == running?.pid else {
                        send(keystrokes, to: reader.name, store: store)
                        return
                    }
                    Log.notice("reader \(reader.name): \(stubborn.name) ignored \(configuration.quitKey), signalling")
                    // Spelled with its module: `ZmxRegistry.kill(_:)` destroys
                    // a whole session, and an unqualified `kill` in an
                    // extension of it resolves to that rather than to the
                    // signal. The compiler catches it, which is luck.
                    Darwin.kill(stubborn.pid, SIGTERM)
                    DispatchQueue.main.asyncAfter(deadline: .now() + Reader.signalGrace) { [weak self] in
                        self?.send(keystrokes, to: reader.name, store: store)
                    }
                }
                return .opened(pane: reader.name)
            }
        }

        // Nothing to reuse, so this creates a pane — and a pane that opens onto
        // a `command not found` is the empty reader the ticket asked us not to
        // make. An existing reader is typed into regardless: there the shell's
        // own error lands in a pane that was already there, which is the
        // cheapest honest way to say it.
        guard Reader.isInstalled(configuration) else {
            return .missingViewer(configuration.viewer)
        }
        guard let anchor = focused ?? sessions.first(where: { $0.tab == tab })?.name else {
            return .noPane
        }
        guard let created = createReader(near: anchor) else { return .noPane }
        DispatchQueue.main.asyncAfter(deadline: .now() + Reader.startupGrace) { [weak self] in
            self?.send(keystrokes, to: created, store: store)
        }
        return .opened(pane: created)
    }

    /// A reader is an ordinary split that carries one more label, so it is the
    /// same placement, the same `ephemeral=1`, and the same everything else.
    ///
    /// Disposable is right even for a pane somebody means to keep: the reaper
    /// vetoes on a session running something other than a login shell, so a
    /// reader with a document open in it is never a candidate, and one sitting
    /// at an idle prompt for twelve hours is exactly the pane that should go.
    @discardableResult
    func createReader(near focused: String, axis: SplitAxis = .horizontal) -> String? {
        guard let created = split(pane: focused, axis: axis) else { return nil }
        Zmx.run(["set", created, "reader=1"])
        refresh()
        return created
    }

    /// Designate a pane, or stop. The label is the whole implementation, which
    /// is the test for whether a feature belongs in this app: `zmx set <name>
    /// reader=1` from any shell does exactly this.
    func setReader(_ isReader: Bool, on session: String) {
        Zmx.run(["set", session, isReader ? "reader=1" : "reader="])
        refresh()
    }

    /// Put keystrokes in a session, whether or not it is on screen.
    ///
    /// The attached path is the honest one: the bytes go down the same `.input`
    /// frame the surface's own keystrokes use, so the daemon cannot tell them
    /// from typing. But a pane in a hidden tab has no surface, and a pane
    /// created half a second ago has not attached yet, and both of those are
    /// ordinary here — the reader may well be created by this very call. `zmx
    /// send` is the same input from the other side of the socket, and it works
    /// on a session nobody is watching.
    private func send(_ text: String, to session: String, store: PaneStore) {
        if let model = store.attachedModel(for: session) {
            model.insert(text)
        } else {
            Zmx.run(["send", session, text])
        }
    }
}

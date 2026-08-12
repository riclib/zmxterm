import Foundation

/// **Open in Editor: a new pane, every time.**
///
/// The reader and the editor look like the same feature and are opposites in
/// the one way that matters. A reader is a stable panel whose *point* is that
/// the next document replaces the last; an editor holds a buffer somebody is
/// typing into, and replacing that is the worst thing this app could do. So
/// there is no `editor=1` label, nothing is ever looked up, and nothing is ever
/// reused: every Open in Editor splits a pane, exactly as the Split menu item
/// would, and forgets about it.
///
/// That is also why nothing here sends a quit key. `Reader` has a careful
/// stop-then-signal dance because it has to clear a pane it means to reuse;
/// this has no such need, and typing a quit key at somebody's vim is precisely
/// the accident the design is avoiding. The pane is the user's from the moment
/// it exists — closing it is their business.
///
/// The reaper reads this correctly without being told: `ephemeral=1` makes the
/// pane a candidate, and the "something other than a login shell is running"
/// veto protects an editor with unsaved work in it. Quit the editor and the
/// pane is an ordinary idle shell, which is exactly when it should be reapable.
enum Editor {
    /// The override, in the shape `readerCommand` had: a command line, with
    /// `{path}` if it wants the file somewhere other than the end.
    static let commandDefaultsKey = "editorCommand"

    /// What to run when the user has expressed no opinion anywhere. `vim` is
    /// on every machine this app runs on and quits without a mouse, which is
    /// the whole requirement for something that opens in a terminal pane.
    static let fallback = "vim"

    /// The editor command, before the file is appended.
    ///
    /// The order is: what was configured here, then what the login shell says
    /// `$EDITOR` is, then `vim`. Asking the shell before falling back is the
    /// point of the middle step — a user who has set `EDITOR` has already
    /// answered this question, and making them answer it again in a second
    /// place is how the two come to disagree.
    ///
    /// `$EDITOR` is taken as a command line rather than as a binary, so
    /// `code -w` keeps its argument. Both parameters are injected so the whole
    /// decision is a pure function; the defaults are what production passes.
    static func command(
        override: String? = UserDefaults.standard.string(forKey: commandDefaultsKey),
        environment: String = Reader.login.editor
    ) -> String {
        let configured = override?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !configured.isEmpty { return configured }
        let inherited = environment.trimmingCharacters(in: .whitespacesAndNewlines)
        if !inherited.isEmpty { return inherited }
        return fallback
    }

    /// The binary to check for, which is not the command line and not a
    /// basename. `Reader.executable(of:)` skips leading `NAME=value`
    /// assignments and keeps a configured path intact — asked of the basename
    /// instead, an `$EDITOR` of `/opt/homebrew/bin/nvim` would be looked up on
    /// the PATH and could answer about a different `nvim` entirely.
    static func executable(of command: String) -> String {
        Reader.executable(of: command)
    }
}

// MARK: - Opening a file

@MainActor
extension ZmxRegistry {
    /// Open `path` in a new pane running the editor.
    ///
    /// Everything that can fail is decided before anything is created, so a
    /// refusal never leaves a bare pane sitting in the layout: a missing editor
    /// is reported while the tab still looks exactly as it did.
    ///
    /// The pane is created by `split`, which is what makes this the same
    /// gesture as splitting by hand — same placement, same `ephemeral=1`, same
    /// sizes rebalanced across the tab. The editor is then typed into it after
    /// `startupGrace`, for the reason that constant exists: `createSession`
    /// returns once the daemon is up, but the login shell inside it is still
    /// starting and a command sent now would land in front of the prompt.
    ///
    /// Returns what it decided immediately; the typing happens a beat later and
    /// cannot change the answer.
    @discardableResult
    func openInEditor(
        path: String,
        tab: String,
        near focused: String?,
        store: PaneStore,
        command: String = Editor.command()
    ) -> Reader.Outcome {
        let executable = Editor.executable(of: command)
        guard Reader.isInstalled(executable: executable) else {
            Log.notice("editor \(executable.isEmpty ? command : executable) not found on the login PATH")
            return .missingEditor(executable.isEmpty ? command : executable)
        }
        // A tab with no pane at all has nothing to split, and `split` needs an
        // existing session to place the new one against.
        guard let anchor = focused ?? sessions.first(where: { $0.tab == tab })?.name else {
            return .noPane
        }
        guard let created = split(pane: anchor, axis: .horizontal) else { return .noPane }
        Log.debug("editor pane \(created) for \(path): \(command)")
        let keystrokes = Reader.keystrokes(command: command, opening: path)
        DispatchQueue.main.asyncAfter(deadline: .now() + Reader.startupGrace) { [weak self] in
            self?.send(keystrokes, to: created, store: store)
        }
        return .opened(pane: created)
    }
}

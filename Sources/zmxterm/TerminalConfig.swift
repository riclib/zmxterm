import Foundation
import GhosttyTerminal

/// Your Ghostty config, used as-is.
///
/// The surface is libghostty, so it parses exactly the file Ghostty parses —
/// there is no mapping layer to write and no subset to maintain. Theme, font,
/// cursor, colours and scrollback all carry over, and a setting added to
/// Ghostty tomorrow works here without a release.
///
/// Settings that only mean something to a whole application — `copy-on-select`,
/// window chrome — are parsed and simply do not apply to an embedded surface.
/// That is preferable to filtering them out: the config stays one file with one
/// meaning, rather than a list of keys this app claims to honour and might be
/// wrong about.
///
/// **`keybind` is the exception, and this comment used to say otherwise.** A
/// binding very much does apply: the surface asks libghostty whether a chord is
/// bound *before* the key reaches the menu, and consumes it if it is. Ghostty
/// binds `super+q=quit` by default, so ⌘Q went to the terminal, produced an
/// action nothing here listens for, and the Quit item never fired. See
/// `appKeybinds`.
@MainActor
enum TerminalConfig {
    /// Ghostty's own search order on macOS.
    private static var candidates: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var paths: [String] = []
        if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            paths.append("\(xdg)/ghostty/config")
        }
        paths.append("\(home)/.config/ghostty/config")
        paths.append("\(home)/Library/Application Support/com.mitchellh.ghostty/config")
        return paths
    }

    static let path: String? = candidates.first { FileManager.default.fileExists(atPath: $0) }

    /// The chords this app owns, taken back from the terminal.
    ///
    /// `AppTerminalView.performKeyEquivalent` asks libghostty whether a chord is
    /// bound before anything else sees it, and consumes it when it is. Ghostty's
    /// defaults bind all four of these, so each one reached the surface, became
    /// an action this app does not implement, and did nothing at all — the menu
    /// and the SwiftUI shortcuts behind them were never offered the key.
    ///
    /// Unbinding is the honest fix rather than intercepting: the chord genuinely
    /// belongs to the application here, and saying so in the config is the same
    /// thing Ghostty itself would understand. Verified against the CLI, where
    /// `--keybind=super+q=unbind` takes `super+q=quit` out of `+list-keybinds`.
    ///
    /// Only chords the app actually binds. `super+c`, `super+v` and the rest
    /// stay with the terminal, which is where a person pressing them means them
    /// to go. `super+k` is Ghostty's `clear_screen` and is left alone until #1
    /// claims it.
    nonisolated static let appKeybinds = """
    # zmxterm binds these itself; the terminal must not claim them first.
    keybind = super+q=unbind
    keybind = super+t=unbind
    keybind = super+d=unbind
    keybind = super+shift+d=unbind
    """

    /// The user's config with ours appended, as text.
    ///
    /// Appended, so a user who deliberately rebinds one of these after this
    /// block wins — the last `keybind` for a chord is the one that stands.
    ///
    /// Handing libghostty text rather than a path costs one thing: a relative
    /// `config-file` inside it would resolve against this process's working
    /// directory instead of the config's own. So those are made absolute on the
    /// way through. Pure, and tested, because it is the sort of transform that
    /// looks obviously right and quietly drops a line.
    nonisolated static func configText(userConfig: String, directory: String) -> String {
        let absolute = userConfig.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("config-file"),
                  let equals = trimmed.firstIndex(of: "="),
                  case let value = trimmed[trimmed.index(after: equals)...]
                      .trimmingCharacters(in: .whitespaces),
                  !value.isEmpty, !value.hasPrefix("/"), !value.hasPrefix("~")
            else { return String(line) }
            return "config-file = \(directory)/\(value)"
        }.joined(separator: "\n")
        return absolute + "\n" + appKeybinds + "\n"
    }

    /// What to hand the controller: the user's file plus our keybinds, or just
    /// ours when there is no file, so ⌘Q works on a machine with no Ghostty
    /// config at all.
    nonisolated static func configSource(path: String?) -> TerminalController.ConfigSource {
        guard let path, let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            return .generated(appKeybinds + "\n")
        }
        return .generated(configText(
            userConfig: text,
            directory: (path as NSString).deletingLastPathComponent
        ))
    }

    /// One controller for every pane. Panes differ in what they are attached to,
    /// never in how they are drawn, so a per-pane controller would only be a way
    /// for them to drift apart.
    static let controller: TerminalController = {
        Log.debug(path.map { "config: loading \($0)" } ?? "config: none found, using defaults")
        // An empty theme is the point. The controller always overlays a
        // TerminalTheme on top of the config it loads, and the default one is a
        // light/dark palette pair — which lands *after* the user's `theme =`
        // line and wins, so their colours would be silently replaced by the
        // library's. Handing it an empty pair leaves the file as the last word.
        //
        // The trade is that panes no longer follow the system appearance. That
        // is correct here: someone who wrote a theme into their Ghostty config
        // has already chosen, and Ghostty itself would not second-guess them.
        // `.generated` rather than `.file`, because our keybinds have to be
        // appended to the user's — see `configSource(path:)`.
        let controller = TerminalController(
            configSource: configSource(path: path),
            theme: TerminalTheme(light: TerminalConfiguration(), dark: TerminalConfiguration())
        )
        Log.debug("config: source=\(controller.currentConfigSource)")
        // A rejected config falls back to defaults, which looks like the
        // config being ignored rather than refused. Say so.
        if case .none = controller.currentConfigSource {
            Log.debug("config: REJECTED \(path) — libghostty found a problem with it and fell back to defaults")
        }
        for line in controller.renderedConfig.split(separator: "\n")
            where line.hasPrefix("theme") || line.hasPrefix("font-family")
            || line.hasPrefix("background-opacity") || line.hasPrefix("scrollback-limit") {
            Log.debug("config:   \(line)")
        }
        return controller
    }()

    /// Re-read the config and push it to every pane at once.
    ///
    /// One controller serves all panes, so a reload is a single call rather
    /// than a walk over surfaces.
    @discardableResult
    static func reload() -> Bool {
        guard let path else { return false }
        let ok = controller.updateConfigSource(configSource(path: path))
        Log.debug("config: reload \(ok ? "applied" : "rejected") \(path)")
        return ok
    }

    /// Watch the config for edits.
    ///
    /// Without this the config is read once at launch, which is a confusing
    /// way to behave: a setting added while the app is running appears not to
    /// work, and the only clue is that it starts working tomorrow.
    ///
    /// Editors rename over the file rather than writing in place, which fires
    /// `.delete`/`.rename` and invalidates the descriptor — so a rewatch is
    /// part of normal operation, not error handling.
    @MainActor
    final class Watcher {
        private var source: DispatchSourceFileSystemObject?
        private var pending: DispatchWorkItem?

        init() { watch() }
        deinit { source?.cancel() }

        private func watch() {
            guard let path = TerminalConfig.path else { return }
            let descriptor = open(path, O_EVTONLY)
            guard descriptor >= 0 else { return }

            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .delete, .rename, .extend],
                queue: .main
            )
            source.setEventHandler { [weak self] in self?.scheduleReload() }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            self.source = source
        }

        /// A save can arrive as several events; apply the last one.
        private func scheduleReload() {
            pending?.cancel()
            let work = DispatchWorkItem { [weak self] in
                TerminalConfig.reload()
                // Re-open: the file this descriptor pointed at may no longer be
                // the file at that path.
                self?.source?.cancel()
                self?.source = nil
                self?.watch()
            }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
        }
    }
}

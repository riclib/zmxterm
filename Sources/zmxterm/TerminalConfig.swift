import Foundation
import GhosttyTerminal

/// Your Ghostty config, used as-is.
///
/// The surface is libghostty, so it parses exactly the file Ghostty parses —
/// there is no mapping layer to write and no subset to maintain. Theme, font,
/// cursor, colours and scrollback all carry over, and a setting added to
/// Ghostty tomorrow works here without a release.
///
/// Settings that only mean something to a whole application — `keybind`,
/// `copy-on-select`, window chrome — are parsed and simply do not apply to an
/// embedded surface. That is preferable to filtering them out: the config stays
/// one file with one meaning, rather than a list of keys this app claims to
/// honour and might be wrong about.
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

    /// One controller for every pane. Panes differ in what they are attached to,
    /// never in how they are drawn, so a per-pane controller would only be a way
    /// for them to drift apart.
    static let controller: TerminalController = {
        guard let path else {
            Log.debug("config: none found, using defaults")
            return TerminalController()
        }
        Log.debug("config: loading \(path)")
        // An empty theme is the point. The controller always overlays a
        // TerminalTheme on top of the config it loads, and the default one is a
        // light/dark palette pair — which lands *after* the user's `theme =`
        // line and wins, so their colours would be silently replaced by the
        // library's. Handing it an empty pair leaves the file as the last word.
        //
        // The trade is that panes no longer follow the system appearance. That
        // is correct here: someone who wrote a theme into their Ghostty config
        // has already chosen, and Ghostty itself would not second-guess them.
        let controller = TerminalController(
            configFilePath: path,
            theme: TerminalTheme(light: TerminalConfiguration(), dark: TerminalConfiguration())
        )
        Log.debug("config: source=\(controller.currentConfigSource)")
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
        let ok = controller.updateConfigSource(.file(path))
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

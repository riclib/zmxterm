import Foundation

/// Point libghostty and terminfo at files we can guarantee exist.
///
/// Two things resolve against Ghostty's resource tree, and both fail in ways
/// that look like something else entirely:
///
/// - `theme = …` resolves against `<resources>/themes`, found via
///   `GHOSTTY_RESOURCES_DIR`. Missing, the theme is a config diagnostic, and a
///   single diagnostic makes libghostty reject the *whole* config and fall back
///   to defaults — so one unresolvable line silently loses every other setting.
/// - `xterm-ghostty` lives in Ghostty's terminfo database, found via `TERMINFO`.
///   Missing, our `infocmp` probe fails and every session gets the lesser
///   `xterm-256color`.
///
/// A shell started *by* Ghostty exports both, which is exactly why this worked
/// when the app was launched from a terminal and failed from the Dock. Rather
/// than depend on the launch context, prefer an installed Ghostty (its themes
/// will be newer than ours) and fall back to the copies we ship.
///
/// `setenv` rather than passing paths around: libghostty reads the environment,
/// and sessions we create inherit it, so a pane's shell can resolve
/// `xterm-ghostty` too.
enum GhosttyResources {
    /// Call once, before anything reads a config or probes terminfo.
    static func locate() {
        let manager = FileManager.default
        let environment = ProcessInfo.processInfo.environment

        let installed = [
            "/Applications/Ghostty.app/Contents/Resources",
            NSHomeDirectory() + "/Applications/Ghostty.app/Contents/Resources",
        ].first { manager.fileExists(atPath: $0 + "/ghostty/themes") }

        let bundled = Bundle.module.resourceURL?.path

        if let existing = environment["GHOSTTY_RESOURCES_DIR"],
           manager.fileExists(atPath: existing + "/themes") {
            // Inherited from a Ghostty shell; leave it alone.
        } else if let resources = installed.map({ $0 + "/ghostty" })
            ?? bundled.map({ $0 + "/ghostty" }),
            manager.fileExists(atPath: resources + "/themes") {
            setenv("GHOSTTY_RESOURCES_DIR", resources, 1)
            Log.debug("resources: themes from \(resources)")
        } else {
            Log.debug("resources: no themes found; `theme =` will not resolve")
        }

        if let existing = environment["TERMINFO"], manager.fileExists(atPath: existing) {
            // Inherited; leave it alone.
        } else if let terminfo = installed.map({ $0 + "/terminfo" }) ?? bundled.map({ $0 + "/terminfo" }),
                  manager.fileExists(atPath: terminfo) {
            setenv("TERMINFO", terminfo, 1)
            Log.debug("resources: terminfo from \(terminfo)")
        }
    }
}

import Foundation

/// Ghostty's shell integration, switched on for sessions this app creates.
///
/// The scripts ship with Ghostty and are found the same way themes and terminfo
/// are — under `GHOSTTY_RESOURCES_DIR`, which `GhosttyResources.locate()` has
/// already resolved by the time a session is created. Turning them on costs
/// only environment variables, and buys the terminal the two things it cannot
/// infer from a byte stream: OSC 7, so the pane knows the shell's working
/// directory as it changes, and OSC 133 prompt marks, so there is something to
/// navigate between.
///
/// A shell started by Ghostty itself gets this env already. A shell started by
/// zmx gets nothing, which is why a pane's directory is currently frozen at
/// whatever `start_dir` said when the session was made.
///
/// Everything here is a pure function of (shell, resources directory, inherited
/// environment) so it can be checked without creating a session — which matters,
/// because the failure mode is a shell that does not start.
enum ShellIntegration {
    /// The variables to add for `shell`, or nothing if it can't be reached this
    /// way or is already set up.
    static func environment(
        shell: String,
        resources: String,
        inherited: [String: String]
    ) -> [String: String] {
        let root = resources + "/shell-integration"

        switch (shell as NSString).lastPathComponent {
        case "zsh":
            let dir = root + "/zsh"
            // The reentrancy trap, and the reason this function exists rather
            // than three lines at the call site. Ghostty's `.zshenv` restores
            // ZDOTDIR from GHOSTTY_ZSH_ZDOTDIR and then sources the user's
            // config from there. Injecting on top of an already-injected
            // environment would set GHOSTTY_ZSH_ZDOTDIR to the integration
            // directory itself, so the restore would point the shell back at
            // Ghostty's `.zshenv` instead of the user's — their `.zshrc` would
            // simply never run. Seeing our own directory already in place means
            // the work is done.
            guard inherited["ZDOTDIR"] != dir else { return [:] }
            var added = ["ZDOTDIR": dir]
            // Only when the user actually had one: the script treats the
            // variable being *set* as "restore this", and an empty value would
            // restore an empty ZDOTDIR rather than unsetting it.
            if let existing = inherited["ZDOTDIR"], !existing.isEmpty {
                added["GHOSTTY_ZSH_ZDOTDIR"] = existing
            }
            return added

        // These three load whatever they find on the data-directory search
        // path, so the integration is a directory to prepend rather than a file
        // to source.
        case "fish":
            return dataDirs(prepending: root + "/fish", to: inherited)
        case "elvish":
            return dataDirs(prepending: root + "/elvish", to: inherited)
        case "nu", "nushell":
            return dataDirs(prepending: root + "/nushell", to: inherited)

        case "bash":
            // Deliberately nothing. Ghostty's bash integration requires the
            // shell to be started in POSIX mode — `ghostty.bash` returns
            // immediately unless `GHOSTTY_BASH_INJECT` is set, and bash only
            // reads `$ENV` at all when invoked with `--posix`. That is an argv
            // change, and `zmx attach` spawns a login `$SHELL` with no
            // arguments we can reach. Setting the variables without the flag
            // would be worse than doing nothing: they would sit in the
            // environment of every child process, doing nothing, looking done.
            return [:]

        default:
            return [:]
        }
    }

    /// The login shell a zmx session will actually start.
    ///
    /// `SHELL` is right when it is there and absent exactly when it matters
    /// least to guess: an app launched from the Dock inherits no login shell's
    /// environment, which is the same launch context that already cost this
    /// codebase its Ghostty config. The password database is what zmx itself
    /// falls back to, so agreeing with it is the point.
    static func loginShell(inherited: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let shell = inherited["SHELL"], !shell.isEmpty { return shell }
        if let entry = getpwuid(getuid()), let raw = entry.pointee.pw_shell {
            let path = String(cString: raw)
            if !path.isEmpty { return path }
        }
        return "/bin/sh"
    }

    /// Prepend `dir` to `XDG_DATA_DIRS`, moving it to the front if it is
    /// already somewhere in the list rather than adding a second copy.
    private static func dataDirs(prepending dir: String, to inherited: [String: String]) -> [String: String] {
        // The XDG default, spelled out because dropping it would be a silent
        // removal of every system data directory rather than an addition.
        let existing = inherited["XDG_DATA_DIRS"].flatMap { $0.isEmpty ? nil : $0 }
            ?? "/usr/local/share:/usr/share"
        let parts = existing.split(separator: ":").map(String.init)
        let rebuilt = [dir] + parts.filter { $0 != dir }
        guard rebuilt != parts else { return [:] }
        return ["XDG_DATA_DIRS": rebuilt.joined(separator: ":")]
    }
}

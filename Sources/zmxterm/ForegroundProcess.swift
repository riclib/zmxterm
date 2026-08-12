import Foundation

/// What each session is actually running, resolved from its process tree.
///
/// `zmx list` reports no `cmd` field, so a session's own record says nothing
/// about what is running inside it — a Claude agent and an idle shell are
/// indistinguishable, and the icon rule falls through to whatever the working
/// directory suggests. The daemon does report a `pid`, and that is enough.
///
/// Shallowest wins, not deepest. An agent spawns MCP servers, language servers
/// and `npm` beneath itself, so the deepest descendant of a Claude session is
/// something like `chrome-devtools-mcp`. The first non-shell process below the
/// session is the one the human would name.
enum ForegroundProcess {
    private static let shells: Set<String> = [
        "bash", "-bash", "zsh", "-zsh", "sh", "-sh", "fish", "-fish", "login", "zmx",
    ]

    /// A process found below a session's shell: what it is called, and which
    /// one it is.
    ///
    /// The pid is not decoration. Stopping a viewer that ignores its own quit
    /// key means signalling it, and a name cannot be signalled — see
    /// `ZmxRegistry.openInReader`.
    struct Running: Equatable {
        let pid: pid_t
        let name: String
    }

    /// One `ps` for every session at once — a call per pane would be silly at
    /// the poll interval.
    static func resolve(sessionPIDs: [String]) -> [String: String] {
        guard !sessionPIDs.isEmpty else { return [:] }

        let tree = scan()
        var resolved: [String: String] = [:]
        for text in sessionPIDs {
            guard let root = pid_t(text) else { continue }
            if let found = firstNonShell(below: root, in: tree) {
                resolved[text] = found.name
            }
        }
        return resolved
    }

    /// The same question about one session, asked at the moment somebody acts
    /// on it rather than on the registry's two-second poll — and answered with
    /// the pid as well as the name.
    ///
    /// A second `ps` rather than a cached tree on purpose: what is running in a
    /// pane is exactly the sort of fact that goes stale between a poll and a
    /// click, and a stale answer here means typing a quit key at a process that
    /// has already gone.
    static func running(sessionPID: String) -> Running? {
        guard let root = pid_t(sessionPID) else { return nil }
        return firstNonShell(below: root, in: scan())
    }

    /// The process table as a tree: who is whose child, and what each one is
    /// called.
    private struct Tree {
        var children: [pid_t: [pid_t]] = [:]
        var command: [pid_t: String] = [:]
    }

    private static func scan() -> Tree {
        var tree = Tree()
        for line in shell("/bin/ps", ["-ax", "-o", "pid=,ppid=,comm="]).split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 3, let pid = pid_t(fields[0]), let parent = pid_t(fields[1]) else { continue }
            tree.children[parent, default: []].append(pid)
            // comm is a path for some processes; the last component is the name.
            tree.command[pid] = fields[2...].joined(separator: " ").split(separator: "/").last.map(String.init) ?? ""
        }
        return tree
    }

    private static func firstNonShell(below root: pid_t, in tree: Tree) -> Running? {
        var queue = tree.children[root] ?? []
        var index = 0
        var seen: Set<pid_t> = [root]

        while index < queue.count {
            let pid = queue[index]
            index += 1
            guard seen.insert(pid).inserted else { continue }
            if let name = tree.command[pid], !shells.contains(name) { return Running(pid: pid, name: name) }
            queue.append(contentsOf: tree.children[pid] ?? [])
        }
        return nil
    }

    /// Not private: `EphemeralReaper` needs a second `ps` view — the tty each
    /// session's shell is on — and a second copy of this would be a second
    /// thing to get wrong about pipe draining.
    static func shell(_ path: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

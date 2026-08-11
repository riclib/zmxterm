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

    /// One `ps` for every session at once — a call per pane would be silly at
    /// the poll interval.
    static func resolve(sessionPIDs: [String]) -> [String: String] {
        guard !sessionPIDs.isEmpty else { return [:] }

        let output = shell("/bin/ps", ["-ax", "-o", "pid=,ppid=,comm="])
        var children: [Int: [Int]] = [:]
        var command: [Int: String] = [:]

        for line in output.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 3, let pid = Int(fields[0]), let parent = Int(fields[1]) else { continue }
            children[parent, default: []].append(pid)
            // comm is a path for some processes; the last component is the name.
            command[pid] = fields[2...].joined(separator: " ").split(separator: "/").last.map(String.init) ?? ""
        }

        var resolved: [String: String] = [:]
        for text in sessionPIDs {
            guard let root = Int(text) else { continue }
            if let found = firstNonShell(below: root, children: children, command: command) {
                resolved[text] = found
            }
        }
        return resolved
    }

    private static func firstNonShell(
        below root: Int,
        children: [Int: [Int]],
        command: [Int: String]
    ) -> String? {
        var queue = children[root] ?? []
        var index = 0
        var seen: Set<Int> = [root]

        while index < queue.count {
            let pid = queue[index]
            index += 1
            guard seen.insert(pid).inserted else { continue }
            if let name = command[pid], !shells.contains(name) { return name }
            queue.append(contentsOf: children[pid] ?? [])
        }
        return nil
    }

    private static func shell(_ path: String, _ arguments: [String]) -> String {
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

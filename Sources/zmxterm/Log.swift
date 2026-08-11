import Foundation

/// Stderr tracing, off unless `ZMXTERM_DEBUG` is set. A GUI with no console is
/// otherwise silent about the thing you actually want to know — whether a pane
/// ever laid out and attached.
enum Log {
    static let enabled = ProcessInfo.processInfo.environment["ZMXTERM_DEBUG"] != nil

    static func debug(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        FileHandle.standardError.write(Data((message() + "\n").utf8))
    }

    /// Written whether or not tracing is on. Reserved for the irreversible: a
    /// session this app destroyed has no undo and leaves no other trace, so the
    /// line naming it has to exist even in a run nobody thought to debug.
    static func notice(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

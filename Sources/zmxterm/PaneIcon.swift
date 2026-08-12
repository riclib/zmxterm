import AppKit
import SwiftUI

/// Which glyph identifies a pane, and how state colours it.
///
/// The rule your rail runs on is that shape says who and colour says whether —
/// and brand marks make that almost free, because a resting Claude pane is the
/// Claude glyph with the colour taken out, and one that wants you is the same
/// glyph at full strength. State is saturation, not hue, so identity never
/// moves and the eye still lands on the one pane that needs a human.
enum PaneIcon {
    private struct Rule {
        let match: String
        let asset: String
        /// Whether the session's directory counts as evidence. What a pane is
        /// *running* identifies it better than where it is running, so agent
        /// marks match on the command and name only — otherwise a whole team
        /// working inside one repo would all wear that project's badge and stop
        /// being tellable apart. Project marks are the fallback, and there the
        /// directory is the point.
        let includesDirectory: Bool
    }

    /// Order is priority: agents first, then projects, then the plain terminal.
    private static let rules: [Rule] = [
        Rule(match: "claude", asset: "claudecode", includesDirectory: false),
        Rule(match: "codex", asset: "codex", includesDirectory: false),
        Rule(match: "grok", asset: "grok", includesDirectory: false),
        Rule(match: "solid", asset: "solid", includesDirectory: true),
    ]

    /// What a pane is running, which is what identifies an agent. Usage
    /// meters use the same haystack so a Claude pane and a Grok pane cannot
    /// disagree about whose quota they are.
    static func runningText(for pane: ZmxSession) -> String {
        (pane.command + " " + pane.name).lowercased()
    }

    static func asset(for pane: ZmxSession) -> String {
        let running = runningText(for: pane)
        let located = (running + " " + pane.startDir).lowercased()
        let matched = rules.first { $0.includesDirectory ? located.contains($0.match) : running.contains($0.match) }
        return matched?.asset ?? "terminal"
    }

    private static var cache: [String: NSImage] = [:]

    static func image(named asset: String) -> NSImage? {
        if let cached = cache[asset] { return cached }
        guard let url = Bundle.module.url(
            forResource: asset, withExtension: "svg", subdirectory: "icons"
        ), let image = NSImage(contentsOf: url) else { return nil }
        // The LobeHub marks declare `width="1em"`, which NSImage reads as a
        // 1×1 point image. The representation is vector, so an explicit size
        // scales cleanly rather than blurring.
        image.size = NSSize(width: 64, height: 64)
        cache[asset] = image
        return image
    }
}

struct AgentIcon: View {
    let pane: ZmxSession
    var size: CGFloat = 14

    var body: some View {
        Group {
            if let image = PaneIcon.image(named: PaneIcon.asset(for: pane)) {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                Image(systemName: "terminal").resizable()
            }
        }
        .aspectRatio(contentMode: .fit)
        .frame(width: size, height: size)
        .saturation(pane.state == nil ? 0 : 1)
        .opacity(pane.state == nil ? 0.5 : 1)
    }
}

/// What a row or a pane header calls itself.
///
/// The tab owns everything before the dot and the pane owns what comes after,
/// so a pane normally shows just its part. That holds as long as parts are
/// unique within the tab — and on a team wall gathering `dev-1.shell` and
/// `dev-2.shell` it isn't, and two rows would both read "shell". When the part
/// doesn't identify it, fall back to the whole name.
enum PaneLabel {
    static func display(_ pane: ZmxSession, among siblings: [ZmxSession]) -> String {
        if let title = pane.title, !title.isEmpty { return title }
        guard let part = pane.part else { return pane.name }
        let ambiguous = siblings.filter { $0.part == part }.count > 1
        return ambiguous ? pane.name : part
    }
}

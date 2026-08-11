import Combine
import Foundation
import SwiftUI

/// One quota meter: the five-hour window, the week, or a per-model limit.
struct UsageMeter: Identifiable, Equatable {
    let id: String
    let label: String
    let percent: Double
    /// Already formatted for display — a clock time for the short window, a
    /// date for the long ones.
    let reset: String?
}

/// Account-level quota, read from the cache Claude Code's own statusline keeps.
///
/// These numbers are identical in every Claude pane — they're the account's,
/// not the session's — so a statusline per terminal spends a line of every pane
/// saying the same thing. Showing them once in the chrome gives that line back.
///
/// Deliberately a reader, not a fetcher: `~/.claude/statusline.sh` already
/// refreshes `/tmp/claude/statusline-usage-cache.json` at most once a minute,
/// so there's no token to find, no API call to make, and no way for this app to
/// spend anyone's rate limit. The cost is that the file only moves while some
/// Claude session is rendering, so a stale file is reported rather than shown
/// as current.
@MainActor
final class UsageMonitor: ObservableObject {
    @Published private(set) var meters: [UsageMeter] = []
    @Published private(set) var isStale = false

    private static let cacheURL = URL(fileURLWithPath: "/tmp/claude/statusline-usage-cache.json")
    /// The script refreshes on a 60s cycle; well past that means nothing is
    /// running to refresh it.
    private static let staleAfter: TimeInterval = 5 * 60

    private var timer: Timer?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    deinit { timer?.invalidate() }

    func refresh() {
        guard let data = try? Data(contentsOf: Self.cacheURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            if !meters.isEmpty { meters = [] }
            return
        }

        let modified = (try? Self.cacheURL.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
        let stale = Date().timeIntervalSince(modified) > Self.staleAfter
        if stale != isStale { isStale = stale }

        var found: [UsageMeter] = []

        if let window = root["five_hour"] as? [String: Any], let pct = window["utilization"] as? Double {
            found.append(UsageMeter(
                id: "cur", label: "cur", percent: pct,
                reset: Self.format(window["resets_at"] as? String, style: .time)
            ))
        }
        if let week = root["seven_day"] as? [String: Any], let pct = week["utilization"] as? Double {
            found.append(UsageMeter(
                id: "wk", label: "wk", percent: pct,
                reset: Self.format(week["resets_at"] as? String, style: .date)
            ))
        }
        // Per-model limits arrive as a list keyed by display name rather than
        // as fixed fields, so the interesting one has to be looked up.
        if let limits = root["limits"] as? [[String: Any]] {
            for limit in limits {
                guard let percent = limit["percent"] as? Double,
                      let scope = limit["scope"] as? [String: Any],
                      let model = scope["model"] as? [String: Any],
                      let name = model["display_name"] as? String
                else { continue }
                found.append(UsageMeter(id: name, label: name.lowercased(), percent: percent, reset: nil))
            }
        }

        Log.debug("usage: " + found.map { "\($0.label)=\(Int($0.percent.rounded()))%\($0.reset.map { " (" + $0 + ")" } ?? "")" }.joined(separator: " · ") + (stale ? " [stale]" : ""))
        if found != meters { meters = found }
    }

    private enum ResetStyle { case time, date }

    private static func format(_ iso: String?, style: ResetStyle) -> String? {
        guard let iso else { return nil }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = parser.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) else { return nil }

        let out = DateFormatter()
        out.dateFormat = style == .time ? "h:mma" : "MMM d"
        out.amSymbol = "am"
        out.pmSymbol = "pm"
        return out.string(from: date).lowercased()
    }
}

extension UsageMeter {
    /// White until half, then warming. The band above 85 is the one that means
    /// "stop and think about what you run next", so it gets the only alarming
    /// colour; 75–85 sits between as orange rather than jumping straight to red.
    var color: Color {
        switch percent {
        case ..<50: .primary
        case ..<75: .yellow
        case ..<85: .orange
        default: .red
        }
    }
}

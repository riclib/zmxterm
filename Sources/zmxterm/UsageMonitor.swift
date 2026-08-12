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

/// File I/O for `Usage`. The decisions live in that enum so `--selftest` can
/// argue about them without a disk; this type just rereads the caches and
/// publishes whatever parsed.
///
/// Still a reader, not a fetcher: each provider's own script refreshes its
/// file, so there is no token to find and no way for this app to spend
/// anyone's rate limit.
@MainActor
final class UsageMonitor: ObservableObject {
    @Published private(set) var caches: [String: Usage.Cache] = [:]
    /// Bumped on every poll so the footer re-asks "is this stale?" even when
    /// the files themselves have not moved. Without it a cache that ages past
    /// five minutes would stay drawn as current until a pane appeared or left.
    @Published private(set) var checkedAt = Date()

    private var timer: Timer?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    deinit { timer?.invalidate() }

    func refresh() {
        var next: [String: Usage.Cache] = [:]
        for provider in Usage.providers {
            let url = URL(fileURLWithPath: provider.cachePath)
            guard let data = try? Data(contentsOf: url) else { continue }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            guard let cache = Usage.read(provider: provider, data: data, modified: modified) else {
                Log.debug("usage: \(provider.id) cache malformed, dropped")
                continue
            }
            next[provider.id] = cache
        }

        let summary = next.keys.sorted().map { id in
            let cache = next[id]!
            return id + "[" + cache.meters.map { "\($0.label)=\(Int($0.percent.rounded()))%" }.joined(separator: " · ") + "]"
        }.joined(separator: " ")
        Log.debug("usage: " + (summary.isEmpty ? "none" : summary))
        if next != caches { caches = next }
        checkedAt = Date()
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

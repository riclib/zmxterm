import Foundation

/// Account-level quota, one provider at a time.
///
/// The shape of this is the feature. The first version read Claude's cache
/// and only Claude's, which was right when that was the only producer. Adding
/// a second agent then meant editing the app — the same trap #23 and #25
/// already hit. An adapter is a name, a match, a path and a format, the
/// built-in ones are three lines of an array, and **adding a producer is a
/// shell script, not a release**.
///
/// The app stays a reader. Nothing here finds a token, calls an API, or
/// spends anyone's rate limit. A provider whose cache is missing, unreadable
/// or malformed is dropped; the rest of the footer stays up.
enum Usage {
    /// How long a cache can sit before it is old news rather than current
    /// news. The Claude statusline refreshes on a 60s cycle; well past that
    /// means nothing is running to refresh it. The same window is the
    /// hysteresis: a provider whose last pane just closed keeps its meters
    /// while the file is still fresh, so they do not vanish mid-glance.
    static let staleAfter: TimeInterval = 5 * 60

    // MARK: - Adapters

    /// One quota producer: what to call it, how to recognise its panes, and
    /// where it writes.
    ///
    /// **To add a provider, add a line here.** The generic format is the
    /// documented schema; Claude's cache predates that and keeps its own
    /// parser so the numbers do not move. A match is the same substring the
    /// icon rules use — what a pane is *running*, never where it is sitting —
    /// so a Claude pane and a Grok pane cannot steal each other's meters.
    struct Provider: Equatable, Identifiable {
        let id: String
        let name: String
        /// Case-insensitive substring of `command + name`, same haystack as
        /// `PaneIcon` for agent marks.
        let match: String
        let cachePath: String
        let format: Format
    }

    enum Format: Equatable {
        /// Claude Code's statusline cache: `five_hour`, `seven_day`, `limits`.
        case claude
        /// The documented schema: `{ "meters": [ { id, label, percent, reset? } ] }`.
        case meters
    }

    /// Built-in producers. Claude is the one that already has a writer;
    /// Grok and Codex are waiting on one. An unknown file at those paths is
    /// ignored until a session of that kind is actually running.
    static let providers: [Provider] = [
        Provider(
            id: "claude", name: "Claude", match: "claude",
            cachePath: "/tmp/claude/statusline-usage-cache.json", format: .claude
        ),
        Provider(
            id: "grok", name: "Grok", match: "grok",
            cachePath: "/tmp/grok/usage.json", format: .meters
        ),
        Provider(
            id: "codex", name: "Codex", match: "codex",
            cachePath: "/tmp/codex/usage.json", format: .meters
        ),
    ]

    // MARK: - What to show

    /// One provider's meters, ready for the footer. `id` is the provider's
    /// so two producers can both ship a meter called `cur` without colliding.
    struct Group: Identifiable, Equatable {
        var id: String { provider.id }
        let provider: Provider
        let meters: [UsageMeter]
        let isStale: Bool
    }

    /// A cache that parsed. Missing, unreadable and malformed files never
    /// become one of these — they drop the provider rather than the footer.
    struct Cache: Equatable {
        let meters: [UsageMeter]
        let modified: Date
    }

    /// Which groups belong in the footer right now.
    ///
    /// A provider shows when it has a parseable cache *and* either a matching
    /// session or a still-fresh file. The second clause is the hysteresis:
    /// closing the last Grok pane must not blank its meters until the file
    /// itself has gone stale. A stale cache with no session is hidden, not
    /// dimmed — dimming is for "this is running but nobody is refreshing".
    static func visible(
        providers: [Provider] = providers,
        caches: [String: Cache],
        sessions: [ZmxSession],
        now: Date,
        staleAfter: TimeInterval = staleAfter
    ) -> [Group] {
        let running = Set(providers.filter { provider in
            sessions.contains { matches($0, provider: provider) }
        }.map(\.id))

        return providers.compactMap { provider in
            guard let cache = caches[provider.id], !cache.meters.isEmpty else { return nil }
            let stale = now.timeIntervalSince(cache.modified) > staleAfter
            let hasSession = running.contains(provider.id)
            guard hasSession || !stale else { return nil }
            return Group(provider: provider, meters: cache.meters, isStale: stale)
        }
    }

    /// Same haystack the icon rules use for agent marks: command and name,
    /// never the directory. A whole team inside one repo would otherwise all
    /// wear the same quota.
    static func matches(_ session: ZmxSession, provider: Provider) -> Bool {
        PaneIcon.runningText(for: session).contains(provider.match)
    }

    // MARK: - Parsing

    /// Bytes and an mtime in, a cache or nothing out. Nothing here touches
    /// the filesystem, which is why `--selftest` can hand it fixtures.
    static func read(provider: Provider, data: Data, modified: Date) -> Cache? {
        let meters: [UsageMeter]?
        switch provider.format {
        case .claude: meters = parseClaude(data)
        case .meters: meters = parseMeters(data)
        }
        guard let meters, !meters.isEmpty else { return nil }
        return Cache(meters: meters, modified: modified)
    }

    /// Claude Code's statusline cache. The field names and the labels (`cur`,
    /// `wk`, the model display name) are the contract with the existing
    /// footer — changing them would be a visual regression, not a cleanup.
    static func parseClaude(_ data: Data) -> [UsageMeter]? {
        guard let root = object(data) else { return nil }

        var found: [UsageMeter] = []

        if let window = root["five_hour"] as? [String: Any], let pct = number(window["utilization"]) {
            found.append(UsageMeter(
                id: "cur", label: "cur", percent: pct,
                reset: format(window["resets_at"] as? String, style: .time)
            ))
        }
        if let week = root["seven_day"] as? [String: Any], let pct = number(week["utilization"]) {
            found.append(UsageMeter(
                id: "wk", label: "wk", percent: pct,
                reset: format(week["resets_at"] as? String, style: .date)
            ))
        }
        if let limits = root["limits"] as? [[String: Any]] {
            for limit in limits {
                guard let percent = number(limit["percent"]),
                      let scope = limit["scope"] as? [String: Any],
                      let model = scope["model"] as? [String: Any],
                      let name = model["display_name"] as? String
                else { continue }
                found.append(UsageMeter(id: name, label: name.lowercased(), percent: percent, reset: nil))
            }
        }

        return found
    }

    /// The documented producer schema.
    ///
    /// ```
    /// { "meters": [ { "id": "cur", "label": "cur", "percent": 42, "reset": "3:20pm" } ] }
    /// ```
    ///
    /// `id` and `label` default to each other; `percent` is required and
    /// accepts an int or a float; `reset` is already formatted, and
    /// `resets_at` is an ISO-8601 fallback formatted as a time if it falls
    /// today and as a date otherwise. A meter missing `percent` is skipped.
    /// A file that is not this object, or whose `meters` is not an array,
    /// is malformed and returns nil so the provider is dropped.
    static func parseMeters(_ data: Data) -> [UsageMeter]? {
        guard let root = object(data), let rows = root["meters"] as? [Any] else { return nil }

        var found: [UsageMeter] = []
        for (index, row) in rows.enumerated() {
            guard let meter = row as? [String: Any], let percent = number(meter["percent"]) else { continue }
            let id = string(meter["id"]) ?? string(meter["label"]) ?? "meter-\(index)"
            let label = string(meter["label"]) ?? id
            let reset = string(meter["reset"]) ?? format(string(meter["resets_at"]), style: .auto)
            found.append(UsageMeter(id: id, label: label, percent: percent, reset: reset))
        }
        return found
    }

    // MARK: - Numbers and dates

    /// JSON numbers arrive as `Int` or `Double` depending on whether they
    /// had a decimal point. The Claude cache writes both (`12` and `12.0`).
    static func number(_ value: Any?) -> Double? {
        switch value {
        case let value as Double: value
        case let value as Int: Double(value)
        case let value as NSNumber: value.doubleValue
        default: nil
        }
    }

    private static func string(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    enum ResetStyle { case time, date, auto }

    /// `auto` picks a time if the instant is today and a date otherwise, so a
    /// producer can ship one ISO field and not have to know which window it
    /// is. Claude keeps the explicit styles because those labels already
    /// mean "this afternoon" and "this week".
    static func format(_ iso: String?, style: ResetStyle, now: Date = Date()) -> String? {
        guard let iso else { return nil }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = parser.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) else { return nil }

        let resolved: ResetStyle = {
            if style != .auto { return style }
            return Calendar.current.isDate(date, inSameDayAs: now) ? .time : .date
        }()

        let out = DateFormatter()
        out.dateFormat = resolved == .time ? "h:mma" : "MMM d"
        out.amSymbol = "am"
        out.pmSymbol = "pm"
        return out.string(from: date).lowercased()
    }
}

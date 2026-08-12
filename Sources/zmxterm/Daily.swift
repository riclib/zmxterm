import Combine
import Foundation

/// Today's daily note, read from whichever PKM app owns it.
///
/// The shape of this is the feature. An earlier version of the idea was closed
/// as too specific to one person — one vault, one note format, one app's URL
/// scheme — and what changed is that **almost none of the work is app-specific**.
/// Finding the file is a vault root plus a path template with a date in it, and
/// both apps store plain markdown in a folder the user chose, so neither could
/// be hardcoded anyway. Parsing is markdown. Only the URL differs, and a URL is
/// a string with two holes in it.
///
/// So an adapter is a `struct` with three fields, the built-in ones are two
/// lines of an array, and **adding a third app is a line, not a fork**. That is
/// the test to apply to any change here: if it makes the second adapter cheap
/// and the third expensive, it has gone wrong.
///
/// This reads an external file exactly as `TerminalConfig` reads a Ghostty
/// config. It is not session state, `zsm` has no opinion about it, and nothing
/// goes near a label.
enum Daily {
    // MARK: - Adapters

    /// One PKM app: what to call it, and how it spells "open this note".
    ///
    /// The template's two holes are the only things any of these need. Neither
    /// scheme addresses a *block*, so neither template has a third — a link
    /// claiming to open a line would quietly land somewhere else, which is
    /// worse than landing at the top of the right note.
    struct Adapter: Equatable {
        /// What you write in the configuration.
        let id: String
        /// What a human calls it, for a message about it.
        let name: String
        /// `{vault}` and `{path}` are filled in, percent-encoded. Everything
        /// else is copied through.
        let template: String

        /// Some apps identify the vault, some do not. A raw template written by
        /// a user may name neither, and then no vault name is needed and none is
        /// asked for.
        var needsVault: Bool { template.contains(Daily.vaultPlaceholder) }
    }

    static let pathPlaceholder = "{path}"
    static let vaultPlaceholder = "{vault}"

    /// **To add an app, add a line here.** Nothing else in this file knows the
    /// difference between them, and nothing outside it knows there is a list.
    static let adapters: [Adapter] = [
        Adapter(
            id: "obsidian", name: "Obsidian",
            template: "obsidian://open?vault={vault}&file={path}"
        ),
        Adapter(
            id: "octarine", name: "Octarine",
            template: "octarine://open?path={path}&workspace={vault}"
        ),
    ]

    /// An adapter by name, or a raw template as an escape hatch.
    ///
    /// The escape hatch matters more than it looks: an app nobody has written
    /// two lines for still works today, without waiting for a release, as long
    /// as its scheme can be written down. Anything containing `{path}` is taken
    /// as a template rather than a name, which is unambiguous — no app is going
    /// to be called that.
    static func adapter(named raw: String) -> Adapter? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let known = adapters.first(where: { $0.id.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return known
        }
        guard trimmed.contains(pathPlaceholder) else { return nil }
        return Adapter(id: "custom", name: "the configured app", template: trimmed)
    }

    /// The URL that opens `path` in `adapter`'s app.
    ///
    /// Everything substituted is percent-encoded against the unreserved set
    /// rather than against `.urlQueryAllowed`, and that is the difference
    /// between working and nearly working: a vault path contains spaces, and
    /// `/` inside a *parameter value* has to be `%2F` or the app reads the
    /// query as structure. `.urlQueryAllowed` passes both `/` and `&` through
    /// untouched, so a note called `Q&A.md` would silently become two
    /// parameters.
    ///
    /// Nil when the adapter names a vault and there is none. A URL built with
    /// an empty vault does not fail — it opens *some* vault, whichever the app
    /// had last — and a link that silently lands somewhere else is the one
    /// outcome worth refusing outright.
    static func url(_ adapter: Adapter, vault: String, path: String) -> URL? {
        guard !path.isEmpty else { return nil }
        guard !adapter.needsVault || !vault.isEmpty else { return nil }
        let filled = adapter.template
            .replacingOccurrences(of: vaultPlaceholder, with: encode(vault))
            .replacingOccurrences(of: pathPlaceholder, with: encode(path))
        return URL(string: filled)
    }

    /// RFC 3986's unreserved set, and nothing else. Everything outside it is
    /// escaped, including `/`, `&`, `?` and `#`.
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }

    // MARK: - Configuration

    /// Everything the module needs, or nothing at all.
    ///
    /// There is no partial state on purpose: `settings` is nil unless every
    /// required piece is there, and nil is what hides the panel. Most people
    /// have no daily note and should see no panel, no placeholder and no
    /// explanation of a feature they did not ask for.
    struct Settings: Equatable {
        var adapter: Adapter
        /// The vault or workspace name *as the app knows it*, which is not
        /// necessarily the folder's name on disk.
        var vault: String
        /// Where the vault is on disk, tilde expanded.
        var root: String
        /// Where today's note is inside it, with date formats in braces:
        /// `Daily/{yyyy-MM-dd}.md`.
        var template: String
    }

    static let adapterDefaultsKey = "dailyAdapter"
    static let vaultDefaultsKey = "dailyVault"
    static let rootDefaultsKey = "dailyRoot"
    static let templateDefaultsKey = "dailyTemplate"

    static var settings: Settings? {
        settings(
            adapter: UserDefaults.standard.string(forKey: adapterDefaultsKey),
            vault: UserDefaults.standard.string(forKey: vaultDefaultsKey),
            root: UserDefaults.standard.string(forKey: rootDefaultsKey),
            template: UserDefaults.standard.string(forKey: templateDefaultsKey)
        )
    }

    /// Read as data so the defaults can be argued about without writing any.
    static func settings(adapter: String?, vault: String?, root: String?, template: String?) -> Settings? {
        guard let adapter = adapter.flatMap({ Daily.adapter(named: $0) }),
              let root = trimmed(root), let template = trimmed(template)
        else { return nil }
        let vault = trimmed(vault) ?? ""
        // Configured-but-unusable is hidden rather than shown broken. The
        // panel's whole point is clicking through to the app; one that cannot
        // build a URL is a list of lines that do nothing when clicked, and a
        // dead click is a worse answer than no panel. `--selftest` prints why.
        guard !adapter.needsVault || !vault.isEmpty else { return nil }
        return Settings(
            adapter: adapter, vault: vault,
            root: (root as NSString).expandingTildeInPath, template: template
        )
    }

    /// Why there is no panel, in one sentence, for the `--selftest` report.
    /// Nothing shows this to a user: it exists because a feature that hides
    /// itself when misconfigured is otherwise impossible to debug.
    static func diagnosis(adapter: String?, vault: String?, root: String?, template: String?) -> String {
        if settings(adapter: adapter, vault: vault, root: root, template: template) != nil {
            return "configured"
        }
        guard let raw = trimmed(adapter) else { return "no \(adapterDefaultsKey) set — panel hidden" }
        guard let chosen = Daily.adapter(named: raw) else {
            return "\(adapterDefaultsKey)=\(raw) is neither a known app "
                + "(\(adapters.map(\.id).joined(separator: ", "))) nor a template containing \(pathPlaceholder)"
        }
        if trimmed(root) == nil { return "no \(rootDefaultsKey) set — panel hidden" }
        if trimmed(template) == nil { return "no \(templateDefaultsKey) set — panel hidden" }
        return "\(chosen.name) needs a vault name in \(vaultDefaultsKey) — panel hidden"
    }

    private static func trimmed(_ value: String?) -> String? {
        let text = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }

    // MARK: - Which file, today

    /// The note's path inside the vault, with `{…}` read as a date format.
    ///
    /// The date is a parameter and never `Date()` inside, for the same reason
    /// `ReapPolicy` takes a clock: a function that reads the calendar itself can
    /// only be tested against today, and "does the path change at midnight" is
    /// exactly the question worth asking. The time zone is a parameter for the
    /// same reason — a daily note belongs to the user's local day, and the one
    /// day a year that is 23 hours long should not move it.
    ///
    /// `en_US_POSIX` so the patterns mean what a template author typed rather
    /// than what the user's region prefers.
    static func relativePath(_ template: String, on date: Date, timeZone: TimeZone = .current) -> String {
        var result = ""
        var literal = ""
        var format = ""
        var inBraces = false

        for character in template {
            switch character {
            case "{" where !inBraces:
                result += literal
                literal = ""
                inBraces = true
            case "}" where inBraces:
                result += formatted(date, format: format, timeZone: timeZone)
                format = ""
                inBraces = false
            default:
                if inBraces { format.append(character) } else { literal.append(character) }
            }
        }
        // An unclosed brace is a typo, not a format: what was typed comes back
        // literally rather than vanishing, so the missing note names the path it
        // looked for and the mistake is visible.
        return result + literal + (inBraces ? "{" + format : "")
    }

    private static func formatted(_ date: Date, format: String, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    /// Vault root plus the note's own path. Joined here so that the two callers
    /// — the reader of the file and the builder of the URL — cannot disagree
    /// about the separator.
    static func absolutePath(root: String, relative: String) -> String {
        (root as NSString).appendingPathComponent(relative)
    }

    // MARK: - What is actually there

    /// The four honest answers about a note file.
    enum Note: Equatable {
        /// No note today, which is the normal state of every morning.
        case missing
        /// iCloud has the name but not the contents. A download has been asked
        /// for; the next refresh will find it.
        case downloading
        case text(String)
        /// It is there and could not be read. Carries the reason, because this
        /// one is not normal and silence would be a bug report nobody can file.
        case unreadable(String)
    }

    /// An evicted iCloud file leaves a hidden placeholder beside where it was:
    /// `Daily/2026-08-12.md` becomes `Daily/.2026-08-12.md.icloud`. So "the file
    /// is not there" and "the file is not *here* yet" look identical to
    /// `fileExists`, and telling a user there is no work today when the note
    /// exists on another machine would be the worst thing this panel could say.
    static func placeholderPath(for path: String) -> String {
        let directory = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        return (directory as NSString).appendingPathComponent(".\(name).icloud")
    }

    static func read(_ path: String) -> Note {
        let url = URL(fileURLWithPath: path)
        let manager = FileManager.default

        if manager.fileExists(atPath: path) {
            // Present but not current: iCloud is holding a stale copy, or is
            // mid-download. Same answer as an eviction — ask, and say so.
            //
            // This check is also what keeps the read below safe to do on the
            // main thread. Reading a ubiquitous file that is not current can
            // block while the system fetches it, and a daily note is otherwise
            // a few kilobytes off the local disk — well under a frame. Asking
            // the status first is the difference between a `stat` and a network
            // round trip in the middle of a layout pass.
            let status = (try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?
                .ubiquitousItemDownloadingStatus
            if let status, status != .current {
                try? manager.startDownloadingUbiquitousItem(at: url)
                return .downloading
            }
            do {
                return .text(try String(contentsOf: url, encoding: .utf8))
            } catch {
                return .unreadable(error.localizedDescription)
            }
        }

        if manager.fileExists(atPath: placeholderPath(for: path)) {
            // The real URL, not the placeholder's: the placeholder is an
            // artefact, and it is the item at the real path that is being
            // asked for.
            try? manager.startDownloadingUbiquitousItem(at: url)
            return .downloading
        }

        return .missing
    }

    // MARK: - Parsing

    /// One top-level bullet: where it was, what it said, and how it draws.
    ///
    /// `id` is the line number rather than the position in the list, so a note
    /// that grows during the day does not renumber every row underneath the one
    /// that was added — the list is newest-first, and new lines land at the
    /// bottom of the file, which is the top of the panel.
    struct Bullet: Identifiable, Equatable {
        let id: Int
        /// The markdown as written, which is what a tooltip should show: it is
        /// the text the user typed, and truncation is the only reason they need
        /// to see it in full.
        let text: String
        /// The same thing with inline markup applied, or plain if it would not
        /// parse.
        let rendered: AttributedString

        init(id: Int, text: String) {
            self.id = id
            self.text = text
            rendered = Daily.attributed(text)
        }
    }

    /// Every top-level bullet in the note, newest first.
    ///
    /// **Top-level only, at column zero.** The sub-bullets under each are the
    /// evidence; the top line is the claim, and the panel is a list of what
    /// changed rather than a copy of the note. An indented bullet is somebody's
    /// supporting detail and is deliberately not promoted by having a short
    /// parent.
    ///
    /// **Newest first**, because a daily note is appended to and the interesting
    /// end is the bottom.
    ///
    /// **All of them.** There used to be a cap of twelve here, and it was a
    /// concession to a panel that might have lived in a footer under the usage
    /// meters. It has a column, so the list is as long as the day was, and
    /// silently dropping the thirteenth thing somebody did today would be a
    /// worse answer than a scrollbar.
    ///
    /// Fenced blocks are skipped, so a shell transcript pasted into the note
    /// cannot contribute `- name` lines it never meant as bullets. Both fence
    /// spellings count, and a fence closes on the same character it opened with,
    /// which is what stops a ``` inside a ~~~ block from ending it early.
    static func bullets(in markdown: String) -> [Bullet] {
        var found: [Bullet] = []
        var fence: Character?

        for (index, raw) in markdown.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = String(raw)

            if let opener = fence {
                if line.hasPrefix(String(repeating: opener, count: 3)) { fence = nil }
                continue
            }
            if line.hasPrefix("```") { fence = "`"; continue }
            if line.hasPrefix("~~~") { fence = "~"; continue }

            // Column zero, marker, space. A leading space makes it a child; no
            // space makes it something else entirely — `*emphasis*`, `--`, a
            // thematic break.
            guard let marker = line.first, marker == "-" || marker == "+" || marker == "*",
                  line.dropFirst().first == " "
            else { continue }

            let text = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            found.append(Bullet(id: index + 1, text: text))
        }

        return found.reversed()
    }

    /// Inline markdown, with plain text as the floor.
    ///
    /// `.inlineOnlyPreservingWhitespace` because these are lines, not documents:
    /// full parsing would read a bullet beginning `# ` as a heading and one
    /// beginning `> ` as a quote, and neither is what a single row shows.
    ///
    /// Malformed input is not hypothetical. A real line in the note this was
    /// built against reads `S**olid's data projections…umns o**ver all…`, with
    /// the emphasis markers a word out of place. Markdown does not reject that
    /// — it bolds the wrong half — and what matters is that every character
    /// still reaches the screen. `.returnPartiallyParsedIfPossible` is what
    /// guarantees that for input that genuinely does not parse, and the `catch`
    /// is the floor under it: this must never be a line that vanishes.
    static func attributed(_ text: String) -> AttributedString {
        do {
            return try AttributedString(
                markdown: text,
                options: AttributedString.MarkdownParsingOptions(
                    interpretedSyntax: .inlineOnlyPreservingWhitespace,
                    failurePolicy: .returnPartiallyParsedIfPossible
                )
            )
        } catch {
            return AttributedString(text)
        }
    }
}

// MARK: - Watching it

/// Today's note, kept current.
///
/// Two clocks, because two different things change. The **file** changes as
/// entries land, which a `DispatchSource` reports the instant it is written —
/// the same watcher `TerminalConfig` uses, rewatching on rename because that is
/// how editors save. The **path** changes at midnight, and no watcher on
/// yesterday's file will ever mention it, so a slow timer re-resolves the whole
/// question. The timer also covers the two cases a file watcher cannot see: a
/// note created later in the day, where there was nothing to watch, and an
/// iCloud download finishing.
@MainActor
final class DailyMonitor: ObservableObject {
    /// Nil when the module is unconfigured, which is what hides the panel.
    @Published private(set) var settings: Daily.Settings?
    /// The note's path inside the vault — the header, and half of the URL.
    @Published private(set) var relativePath = ""
    @Published private(set) var note: Daily.Note = .missing
    @Published private(set) var bullets: [Daily.Bullet] = []

    private var source: DispatchSourceFileSystemObject?
    private var watchedPath: String?
    private var timer: Timer?
    private var pending: DispatchWorkItem?

    init(clock: TimeInterval = 30) {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: clock, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    deinit {
        source?.cancel()
        timer?.invalidate()
    }

    /// Resolve the path from scratch, read it, parse it. Cheap enough to run on
    /// a timer: one `stat`, and a file of a few kilobytes when there is one.
    func refresh(now: Date = Date()) {
        let settings = Daily.settings
        if settings != self.settings { self.settings = settings }

        guard let settings else {
            if !bullets.isEmpty { bullets = [] }
            watch(nil)
            return
        }

        let relative = Daily.relativePath(settings.template, on: now)
        if relative != relativePath { relativePath = relative }

        let absolute = Daily.absolutePath(root: settings.root, relative: relative)
        let read = Daily.read(absolute)
        if read != note { note = read }

        let parsed: [Daily.Bullet] = if case let .text(markdown) = read {
            Daily.bullets(in: markdown)
        } else {
            []
        }
        if parsed != bullets { bullets = parsed }

        // Watch wherever today's note is, even when it does not exist yet: the
        // path is what identifies it, and re-resolving is what handles it
        // appearing.
        watch(absolute)
    }

    /// The absolute path of the note this panel is about, for opening it.
    var absolutePath: String? {
        settings.map { Daily.absolutePath(root: $0.root, relative: relativePath) }
    }

    /// The URL that opens today's note in its app, or nil if there is nothing
    /// to open.
    var url: URL? {
        guard let settings, case .text = note else { return nil }
        return Daily.url(settings.adapter, vault: settings.vault, path: relativePath)
    }

    private func watch(_ path: String?) {
        guard path != watchedPath else { return }
        source?.cancel()
        source = nil
        watchedPath = path

        guard let path else { return }
        let descriptor = open(path, O_EVTONLY)
        // No file yet is the normal state of every morning, and not an error:
        // the timer will pick it up when it is written.
        guard descriptor >= 0 else {
            watchedPath = nil
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .extend],
            queue: .main
        )
        source.setEventHandler { [weak self] in self?.scheduleRefresh() }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
    }

    /// A save arrives as several events, and a note being written to by an app
    /// syncing it can arrive as many. Apply the last.
    private func scheduleRefresh() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // The descriptor may now point at a file that no longer has this
            // path — editors and sync engines both rename over — so the watch is
            // rebuilt from scratch rather than trusted.
            watch(nil)
            refresh()
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }
}

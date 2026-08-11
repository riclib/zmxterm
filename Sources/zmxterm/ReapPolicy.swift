import Foundation

/// Which scratch panes are safe to destroy — and, far more importantly, which
/// are not.
///
/// Every split and every new tab writes `ephemeral=1`, and naming a pane is
/// what promotes it out of being disposable (see `ZmxRegistry.setEphemeral`).
/// Nothing ever removed the disposable ones, so they accumulate as real zmx
/// sessions with real shells in them, forever.
///
/// The whole decision is this pure function, because the consequence of getting
/// it wrong is somebody's unfinished work disappearing with no undo. `now` is a
/// parameter and never `Date()`: a policy that reads the clock itself can only
/// be tested against the clock, which means the interesting cases — the hour
/// before the threshold, the hour after — cannot be tested at all.
///
/// The shape of every rule below is the same: **a veto**. `ephemeral=1` plus
/// nobody attached is the entry ticket, and then any evidence at all that a
/// human or an agent has a stake in this session keeps it. Signals only ever
/// argue for keeping, never for reaping, so a sensor that breaks, a `ps` that
/// returns nothing, a field the daemon stops reporting — all of them fail
/// towards doing nothing.
enum ReapPolicy {
    /// What the policy needs to know that `zmx list` does not report. Passed in
    /// rather than gathered inside, so the tests describe a machine rather than
    /// running on one.
    struct Facts: Equatable {
        /// The first non-shell process below the session's shell, as
        /// `ForegroundProcess` resolves it. Nil means the session is running
        /// nothing but its own login shell.
        var foreground: String?

        /// The last time bytes crossed the session's terminal, or nil if we
        /// could not find out.
        ///
        /// Read carefully, because it is easy to believe this says more than it
        /// does. There is no "last touched" field in zmx, and the obvious place
        /// to look for one is a lie: a unix socket's mtime is set when the
        /// socket is created and does not move when traffic crosses it, so the
        /// session's socket says only what `created` already said. The pty
        /// *device node* is different — devfs stamps it on reads and writes
        /// through the tty — so it is a genuine time of last I/O.
        ///
        /// What it cannot tell you is who caused the I/O. A background job
        /// printing a line looks exactly like a keystroke. That asymmetry
        /// happens to be the right way round for a reaper: anything resembling
        /// life keeps the session, and only a terminal that has been silent for
        /// the whole window counts as quiet.
        var lastActivity: Date?

        static let unknown = Facts(foreground: nil, lastActivity: nil)
    }

    /// How long is long enough. Hours rather than minutes, deliberately: the
    /// cost of reaping late is a stale pane in the rail, and the cost of
    /// reaping early is destroying a shell somebody stepped away from.
    struct Thresholds {
        /// A pane has to have existed for this long before it can be judged
        /// abandoned. Twelve hours means a pane opened during a working day
        /// survives that day whatever else is true of it.
        var minimumAge: TimeInterval = 12 * 60 * 60

        /// …and its terminal has to have been silent for this long. Same span:
        /// anything touched since yesterday is somebody's current context.
        var minimumQuiet: TimeInterval = 12 * 60 * 60

        /// What both spans become for the last pane of a tab.
        ///
        /// Losing a surplus pane from a wall is tidying; losing the last one
        /// takes the tab with it, and a tab is a place you navigate to by name
        /// rather than a slot in a layout. That asymmetry is real, but it is a
        /// difference of degree, so it buys a longer wait rather than
        /// permanent immunity — a week of silence is not a workspace.
        var soloMultiplier: Double = 14

        static let `default` = Thresholds()
    }

    /// The verdict carries the reason, because "why is this pane still here" is
    /// a question a user will ask, and because the tests are far more useful
    /// when they can assert *which* veto fired rather than only that one did.
    enum Verdict: Equatable {
        case reap
        case keep(String)

        var isReap: Bool { self == .reap }

        var reason: String {
            switch self {
            case .reap: return "reapable"
            case let .keep(why): return why
            }
        }
    }

    /// The labels this build knows the meaning of.
    ///
    /// Anything outside this set vetoes a reap. The field namespace is shared:
    /// an orchestrator can invent a label, a future version of this app will
    /// add some, and the daemon has fields of its own that arrive in the same
    /// tab-separated line — `ended` and `exit_code` appear on a task session
    /// the moment its command exits, and `zmx set … ended=` cannot remove them
    /// because they were never labels. `Zmx.list` cannot tell those apart from
    /// labels, so they land here, and the effect is that a session started with
    /// `zmx run` is never reaped. That is the correct direction to be wrong in:
    /// a field this build cannot interpret means somebody else has a stake in
    /// the session, and the honest response to not understanding something is
    /// to leave it alone.
    static let knownLabels: Set<String> = ["ephemeral", "pos", "size", "tab", "title", "state"]

    /// The judgement for one session. `sessions` is the whole list because two
    /// of the vetoes are about a pane's neighbours, not about the pane.
    static func verdict(
        for session: ZmxSession,
        among sessions: [ZmxSession],
        facts: Facts,
        now: Date,
        thresholds: Thresholds = .default
    ) -> Verdict {
        // The entry ticket. Only panes the app itself marked disposable are
        // even candidates; a session created in a terminal has never been
        // anyone's scratch.
        guard session.isEphemeral else { return .keep("not ephemeral") }

        // Somebody is looking at it right now. This is the weakest of the
        // signals — the issue is precisely that a scratch pane sits at zero
        // clients forever — but it is the one that would be unforgivable to
        // skip, because a reap here is a window going blank under a human.
        guard session.clients == 0 else { return .keep("\(session.clients) client(s) attached") }

        // Naming something is explicitly what promotes it out of being
        // disposable; the "Keep" menu item is exactly this label. A pane that
        // still says `ephemeral=1` *and* has a title is a pane whose labels
        // disagree, and between "disposable" and "someone typed a name for it"
        // the name wins.
        if let title = session.title, !title.isEmpty { return .keep("titled \(title)") }

        // `waiting` or `failed` is an agent asking for a human. Reaping one is
        // destroying the question along with whoever was asking it — and note
        // that a pane can be `waiting` at zero clients for hours, which is the
        // normal case, not an unusual one.
        if let state = session.state, !state.isEmpty { return .keep("state=\(state)") }

        // See `knownLabels`: a label we cannot interpret means somebody else
        // has a stake in this session.
        let unknown = session.labels.keys.filter { !knownLabels.contains($0) }.sorted()
        if let first = unknown.first { return .keep("carries \(first)") }

        // Something is running in it. `ForegroundProcess` resolves the first
        // non-shell process below the session, which is how the icons already
        // tell an agent from an idle shell; here the same fact means a build, a
        // pager, an editor with unsaved work, or an agent mid-task. Only a
        // session that is nothing but its own login shell can be scratch.
        if let foreground = facts.foreground, !foreground.isEmpty {
            return .keep("running \(foreground)")
        }

        // A pane whose `tab` label disagrees with the tab its name implies was
        // deliberately gathered somewhere — an orchestrator building a team
        // wall sets `tab=spike` on panes from several different sessions. That
        // is an act of arrangement, and arranged is the opposite of scratch.
        let impliedTab = session.name.split(separator: ".", maxSplits: 1).first.map(String.init) ?? session.name
        if let labelled = session.labels["tab"], labelled != impliedTab {
            return .keep("gathered into \(labelled)")
        }

        // The last pane of a tab waits longer, but it does wait rather than
        // being immune.
        //
        // A tab is something a human refers to out loud — that is why tabs get
        // Guide names and panes get numbers — so taking the last pane takes a
        // place you navigate to, where taking a surplus pane off a wall is the
        // tidying this feature exists for. That asymmetry is real. Answering it
        // with a permanent veto is what is wrong: a new tab nobody named and
        // nobody used is precisely what `ephemeral=1` was invented for, and a
        // policy that can never reap one only tidies walls, which is half the
        // issue. So the difference in kind becomes a difference in degree.
        let tabMates = sessions.filter { $0.tab == session.tab && $0.name != session.name }
        let solo = tabMates.isEmpty
        let scale = solo ? thresholds.soloMultiplier : 1

        // Age, and the two ways of not knowing it. Unknown is not young and it
        // is not old; it is a fact we failed to gather, and a reaper that
        // guesses in that situation is a reaper that deletes when the daemon
        // changes its output format.
        guard let created = session.createdAt else { return .keep("age unknown") }
        let age = now.timeIntervalSince(created)
        if age < thresholds.minimumAge * scale {
            return .keep(solo ? "the only pane in its tab, and only \(hours(age)) old" : "only \(hours(age)) old")
        }

        // …and silence. Age alone would reap the pane you opened this morning,
        // left running a long build in, and came back to after lunch.
        guard let touched = facts.lastActivity else { return .keep("last activity unknown") }
        let quiet = now.timeIntervalSince(touched)
        if quiet < thresholds.minimumQuiet * scale {
            return .keep(solo ? "the only pane in its tab, and active \(hours(quiet)) ago" : "active \(hours(quiet)) ago")
        }

        return .reap
    }

    /// Every session the policy would destroy, in the order it would do it.
    ///
    /// Candidates are considered oldest first against a shrinking list, which
    /// matters for exactly one reason: "never take the last pane of a tab" is a
    /// statement about the tab as it will be, not as it was. A tab holding two
    /// equally stale scratch panes must lose one and keep one, and evaluating
    /// every pane against the original list would let it lose both.
    static func reapable(
        from sessions: [ZmxSession],
        facts: [String: Facts],
        now: Date,
        thresholds: Thresholds = .default
    ) -> [String] {
        let candidates = sessions.sorted { left, right in
            switch (left.createdAt, right.createdAt) {
            case let (l?, r?) where l != r: return l < r
            case (nil, _?): return false
            case (_?, nil): return true
            default: return left.name < right.name
            }
        }

        var survivors = sessions
        var doomed: [String] = []
        for candidate in candidates {
            guard verdict(
                for: candidate,
                among: survivors,
                facts: facts[candidate.name] ?? .unknown,
                now: now,
                thresholds: thresholds
            ).isReap else { continue }
            survivors.removeAll { $0.name == candidate.name }
            doomed.append(candidate.name)
        }
        return doomed
    }

    private static func hours(_ interval: TimeInterval) -> String {
        String(format: "%.1fh", interval / 3600)
    }
}

/// The one place in the app that destroys a session nobody asked it to destroy.
///
/// Everything irreversible lives behind the single `guard` in `runOnLaunch`.
/// Fact gathering is separate and read-only on purpose, so that a dry run —
/// `--selftest` prints one — can exercise the whole pipeline without there
/// being a code path from it to `zmx kill`.
enum EphemeralReaper {
    /// Off unless someone turns it on, and off is the absence of the key:
    /// `UserDefaults.bool(forKey:)` returns false for a key that was never
    /// written, so there is no default to register and no way for a failed
    /// registration to leave the destructive path armed.
    ///
    /// A preference is not session state and this does not break the one rule.
    /// The rule is that nothing describing a zmx session may live in the app —
    /// no layout cache, no tab database — because such a thing can disagree
    /// with zmx. This describes the *user*: whether they want tidying done on
    /// their behalf. It names no session, and `zsm` showing it would be absurd.
    ///
    /// There is deliberately no menu item. A destructive preference one
    /// mis-click away is a worse thing to own than an undiscoverable one, and
    /// the dry run in `--selftest` is how you decide whether you want it.
    ///
    ///     defaults write land.liberato.zmxterm reapEphemeralOnLaunch -bool true
    static let defaultsKey = "reapEphemeralOnLaunch"

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: defaultsKey) }

    /// One pass, at launch, and only ever at launch. A timer would mean a pane
    /// disappearing while somebody is looking at the window, which is both
    /// alarming and much harder to reason about than a decision taken once
    /// against a list that is not moving.
    ///
    /// `kill` is injectable so the plumbing can be exercised with a recorder in
    /// place of the real thing; the default is the same argv `ZmxRegistry.kill`
    /// has always used.
    static func runOnLaunch(kill: (String) -> Void = { Zmx.run(["kill", $0, "--force"]) }) {
        guard isEnabled else {
            Log.debug("reaper: disabled (\(defaultsKey) unset)")
            return
        }

        let sessions = Zmx.list()
        let facts = gatherFacts(for: sessions)
        let now = Date()

        for session in sessions.sorted(by: { $0.name < $1.name }) {
            let verdict = ReapPolicy.verdict(
                for: session, among: sessions, facts: facts[session.name] ?? .unknown, now: now
            )
            Log.debug("reaper: \(session.name) — \(verdict.reason)")
        }

        for name in ReapPolicy.reapable(from: sessions, facts: facts, now: now) {
            Log.notice("reaper: killing ephemeral session \(name)")
            kill(name)
        }
    }

    /// Read-only, and the reason the whole thing fails safe.
    ///
    /// Both facts come from `ps`. If `ps` gives nothing — sandboxed, denied,
    /// changed its output — then every session looks like it is running nothing
    /// *and* has no resolvable terminal, and the "last activity unknown" veto
    /// keeps all of them. The two facts sharing one failure mode is deliberate:
    /// the pessimistic one is the one that decides.
    static func gatherFacts(for sessions: [ZmxSession]) -> [String: ReapPolicy.Facts] {
        let pids = sessions.map(\.pid)
        let foreground = ForegroundProcess.resolve(sessionPIDs: pids)
        let terminals = terminals(for: Set(pids))

        var facts: [String: ReapPolicy.Facts] = [:]
        for session in sessions {
            facts[session.name] = ReapPolicy.Facts(
                foreground: foreground[session.pid],
                lastActivity: terminals[session.pid].flatMap(lastWrite(toTerminal:))
            )
        }
        return facts
    }

    /// One `ps` for every session's tty at once, matching the way
    /// `ForegroundProcess` reads the process table. A session with no
    /// controlling terminal — `ps` prints `??` — is simply absent from the
    /// result, which reads downstream as "unknown", which keeps it.
    private static func terminals(for pids: Set<String>) -> [String: String] {
        var found: [String: String] = [:]
        for line in ForegroundProcess.shell("/bin/ps", ["-ax", "-o", "pid=,tty="]).split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 2 else { continue }
            let pid = String(fields[0])
            let tty = String(fields[1])
            guard pids.contains(pid), tty.hasPrefix("tty") else { continue }
            found[pid] = tty
        }
        return found
    }

    private static func lastWrite(toTerminal tty: String) -> Date? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: "/dev/" + tty)
        return attributes?[.modificationDate] as? Date
    }
}

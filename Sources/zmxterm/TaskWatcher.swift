import Foundation

/// Turning a failed command into the same `state=failed` an agent would set by
/// hand, so a plain shell running `zig build` colours its own card with no hook,
/// no shell integration and no agent involved.
///
/// The reading comes from an `.info` round trip per session rather than from
/// the `zmx list` the registry already runs. `list` does in fact print `ended=`
/// and `exit_code=` — undocumented, and only on a session that has finished a
/// task — but it prints them into the same tab-separated stream as the labels,
/// where the app cannot tell them from a label a human set and where every
/// completed task would silently invent two. `.info` hands over the same two
/// numbers as typed fields at known offsets, which is also what makes the
/// decoder testable from a captured payload. Everything this watcher *decides*
/// lives in the pure function below, for the same reason.
///
/// ## What the daemon actually knows — read this before extending it
///
/// Two limits, both measured against zmx 0.7.0 rather than assumed, and both
/// upstream's rather than ours:
///
/// 1. **`task_exit_code` only tracks `zmx run`.** `zmx run` is task mode: it
///    appends a `ZMX_TASK_COMPLETED:$?` marker to the command and the daemon
///    reads the exit status out of that. A command *typed* into an interactive
///    shell produces no marker, so `task_ended_at` and `task_exit_code` do not
///    move at all — verified by sending `bash exits-7.sh` with `zmx send` and
///    watching all 552 bytes of `Info` stay put while the shell's own prompt
///    happily showed the 7. Making a typed `zig build` turn its pane red needs
///    shell integration, which is a different feature.
///
/// 2. **The exit code latches at a session's first task.** Every later task
///    moves `task_ended_at` and leaves `task_exit_code` alone. Run 3, 5, 7, 0, 3
///    down one session and the field reads 3 throughout; run 0 first and it
///    reads 0 forever, through a failing build, whatever the login shell is.
///    The daemon's own log agrees with the stale field (`task completed
///    exit_code=3` five times) and so does `zmx wait`, so this is zmx's bug and
///    not a misreading of the layout.
///
/// The rule below is written for a daemon that reports honestly, because that
/// is what the app should do when zmx fixes this and what it would have to be
/// rewritten into otherwise. What limit 2 costs us today: a session whose first
/// task failed can be flagged again by a *later* task that actually succeeded.
/// The `state` guard in `shouldFlagFailure` is what keeps that from being
/// destructive — it can produce a stale red on a pane nobody has looked at yet,
/// never a red over the top of an agent's `waiting`.
enum ZmxTaskWatch {
    /// Should this session be flagged `failed` right now?
    ///
    /// Three conditions, each of which is load-bearing:
    ///
    /// - **A transition we witnessed.** `lastEndedAt` is the value from the
    ///   previous poll of this same session; `nil` means we have never seen it
    ///   and this poll is only establishing a baseline. Firing on the current
    ///   value instead would repaint every long-dead failure red at launch, and
    ///   re-firing on an unchanged value would make a poll loop out of what is
    ///   meant to be an event.
    /// - **A non-zero exit.** A zero exit does nothing whatsoever. It very
    ///   deliberately does not *clear* `state`: an agent sets `state=waiting`
    ///   to say it needs a human, and a background build finishing cleanly is
    ///   not an answer to that.
    /// - **No `state` already set.** Only ever write into an empty slot. The
    ///   label is somebody else's signal — an agent's `waiting`, or a `failed`
    ///   the human has not acknowledged yet — and a report of a fact is never
    ///   worth destroying a request for attention. Clearing is the human's, by
    ///   focusing the pane.
    static func shouldFlagFailure(state: String?, exitCode: Int32, endedAt: Int64, lastEndedAt: Int64?) -> Bool {
        guard let lastEndedAt else { return false }
        guard endedAt > lastEndedAt else { return false }
        guard exitCode != 0 else { return false }
        return state == nil
    }
}

/// Polls `.info` for every live session and applies the rule above.
///
/// The last `task_ended_at` per session lives here, in memory, and nowhere
/// else. That is not a breach of "the app owns no session state": losing it
/// costs nothing, because the only thing it can do is make the first poll after
/// a launch treat whatever is there as already seen — which is exactly what we
/// want anyway. A state *file* would be a second source of truth about
/// sessions, and there is never a reason for one of those.
@MainActor
final class ZmxTaskWatcher {
    /// Turn the whole thing off with
    /// `defaults write <domain> flagFailedTasks -bool false`.
    ///
    /// On by default, because writing `state=failed` from a real exit code is
    /// the feature and a switch defaulting off would be a feature nobody has.
    /// It exists at all because of the exit-code latch described above: this
    /// watcher writes into `state`, and `state` is the one channel telling a
    /// human which pane wants them. A false red there costs more than a missing
    /// one, so there has to be a way to silence it that is cheaper than
    /// reverting a build — especially since the bug it guards against is
    /// upstream's, and whoever hits it cannot fix it here.
    static let defaultsKey = "flagFailedTasks"

    static var isEnabled: Bool {
        // `bool(forKey:)` alone cannot express "unset", and unset has to mean
        // on, so ask whether the key exists before believing its value.
        guard UserDefaults.standard.object(forKey: defaultsKey) != nil else { return true }
        return UserDefaults.standard.bool(forKey: defaultsKey)
    }

    private var lastEndedAt: [String: Int64] = [:]
    private var probing = false
    private let queue = DispatchQueue(label: "zmxterm.taskwatch")

    /// Probe every session and flag the ones whose latest task failed.
    ///
    /// Re-entrancy matters here, not for the bookkeeping but for the sockets: a
    /// session whose daemon is wedged costs a full read timeout, and the
    /// registry's two-second poll would otherwise stack probes on top of each
    /// other until the queue is nothing but retries of the same dead socket.
    ///
    /// `refresh` is called only when a label was actually written. Calling it
    /// after every poll would be a loop, since the poll is driven by the
    /// refresh — and a `@Published` reassignment twice a second is a repaint of
    /// the whole sidebar for nothing.
    func poll(_ sessions: [ZmxSession], then refresh: @escaping @MainActor () -> Void) {
        // Checked per poll rather than cached at init so that flipping the
        // default takes effect on the next tick instead of the next launch —
        // the point of the switch is to stop a pane going red *now*.
        guard Self.isEnabled, !probing, !sessions.isEmpty else { return }
        probing = true

        let states = sessions.map { (name: $0.name, state: $0.state) }
        queue.async { [weak self] in
            let infos = states.compactMap { entry -> (String, ZmxInfo)? in
                ZmxClient.info(session: entry.name).map { (entry.name, $0) }
            }
            Task { @MainActor in
                guard let self else { return }
                let failed = self.reconcile(infos, states: states)
                self.probing = false
                guard !failed.isEmpty else { return }
                // The write is a `zmx set` subprocess each, so it happens off
                // the main thread even though the decision was made on it.
                self.queue.async {
                    for name in failed { Zmx.run(["set", name, "state=failed"]) }
                    Task { @MainActor in refresh() }
                }
            }
        }
    }

    /// Fold this round's readings into the baseline and name the sessions to
    /// flag. Separate from the socket work so the ordering is obvious: the
    /// stamp is recorded for *every* session read, including the ones that pass
    /// no rule, or a session whose build failed while its pane was `waiting`
    /// would be flagged the moment the human cleared that label.
    private func reconcile(_ infos: [(String, ZmxInfo)], states: [(name: String, state: String?)]) -> [String] {
        let byName = Dictionary(uniqueKeysWithValues: states.map { ($0.name, $0.state) })
        var failed: [String] = []
        for (name, info) in infos {
            let previous = lastEndedAt[name]
            lastEndedAt[name] = info.taskEndedAt
            guard ZmxTaskWatch.shouldFlagFailure(
                state: byName[name] ?? nil,
                exitCode: info.taskExitCode,
                endedAt: info.taskEndedAt,
                lastEndedAt: previous
            ) else { continue }
            Log.debug("task watch: \(name) exited \(info.taskExitCode) at \(info.taskEndedAt) → state=failed")
            failed.append(name)
        }
        // Sessions come and go; a stamp kept for a name that no longer exists
        // would hand a stale baseline to a future session that reuses it.
        let live = Set(states.map(\.name))
        lastEndedAt = lastEndedAt.filter { live.contains($0.key) }
        return failed
    }
}

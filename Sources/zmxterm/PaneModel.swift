import Combine
import Foundation
import GhosttyTerminal

/// A live surface bound to one zmx session.
///
/// The terminal owns no process: bytes it produces are keystrokes bound for the
/// session, bytes the session produces are fed back in. Closing this detaches —
/// the session, and whatever is running in it, carries on.
@MainActor
final class PaneModel: ObservableObject {
    let terminal = TerminalViewState(controller: TerminalConfig.controller)
    let sessionName: String

    @Published private(set) var isAttached = false
    @Published private(set) var gridSummary = ""

    private let client: ZmxClient
    private var session: InMemoryTerminalSession!
    private var didAttach = false
    private var pendingResize: DispatchWorkItem?
    /// The surface the daemon's last screen send was aimed at.
    ///
    /// Weak on purpose. A tab switch throws the surface away and builds a new
    /// one, and nothing tells the model that happened — but the reference
    /// empties itself when the old surface is released, so "is this the surface
    /// I last painted into" needs no teardown callback to be right. Comparing
    /// bare identities would not do: a freed surface's address can come back on
    /// the next allocation, and a recycled address would read as unchanged.
    private weak var paintedSurface: TerminalSurface?

    init(sessionName: String) {
        self.sessionName = sessionName
        client = ZmxClient(sessionName: sessionName)

        session = InMemoryTerminalSession(
            write: { [client] data in client.send(.input, data) },
            resize: { [weak self] viewport in self?.handleViewport(viewport) }
        )
        client.onOutput = { [session] data in session?.receive(data) }
        client.onClose = { [weak self] in
            Task { @MainActor in self?.isAttached = false }
        }

        terminal.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
        Log.debug("pane model created: \(sessionName)")
    }

    deinit {
        client.detach()
    }

    /// The grid size isn't known until the surface lays out, and `.Init` must
    /// carry one, so the attach waits for the first viewport callback.
    private nonisolated func handleViewport(_ viewport: InMemoryTerminalViewport) {
        let size = ZmxResize(
            rows: viewport.rows,
            cols: viewport.columns,
            xpixel: UInt16(clamping: viewport.widthPixels),
            ypixel: UInt16(clamping: viewport.heightPixels)
        )
        Task { @MainActor in scheduleResize(size) }
    }

    /// SwiftUI settles a nested split tree over several layout passes, so the
    /// first viewport a pane sees can be a sliver — 12 columns before it lands
    /// on 99. Every one of those would be a real `.Resize` reflowing the session
    /// for every other client watching it, so coalesce and apply the last.
    ///
    /// A rebuilt pane settles the same way: three viewports on a tab switch,
    /// the middle one a sliver. Coalescing them is what makes the repaint below
    /// run once on the size the pane actually ended up at.
    private func scheduleResize(_ size: ZmxResize) {
        pendingResize?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.attachOrResize(size) }
        pendingResize = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func attachOrResize(_ size: ZmxResize) {
        Log.debug("viewport \(sessionName): \(size.cols)x\(size.rows)")
        guard size.rows > 0, size.cols > 0 else { return }
        gridSummary = "\(size.cols)×\(size.rows)"

        guard didAttach else {
            didAttach = true
            // An attach replays the screen by itself, so the surface this one
            // laid out on is already painted.
            paintedSurface = terminal.surface
            do {
                try client.attach(size: size)
                isAttached = true
            } catch {
                gridSummary = "attach failed"
            }
            return
        }

        // Unconditional but self-cancelling: the client drops a resize that
        // matches the size it last sent, which is every resize a tab switch
        // produces. It matters on the rare rebuild that *is* a different size —
        // the window was resized while this tab was hidden — because the
        // repaint below replays at whatever size the daemon last heard.
        client.resize(size)

        // Everything past here is the rebuild case. A tab switch destroys the
        // surface and builds a new one while the client stays attached, and
        // `InMemoryTerminalSession` does not buffer: output that arrived while
        // there was no surface was written nowhere, not queued. So the pane
        // comes back empty and only asking the daemon to send the screen again
        // fills it.
        //
        // Asking has to wait for the new surface to be bound, which is why this
        // lives here rather than in the view's `onAppear` — a repaint fired
        // from `onAppear` runs before the representable has made a surface, and
        // the replay it triggers is dropped exactly like the output was. This
        // is the first place that runs afterwards: a rebuilt view reports a
        // viewport, and that report is what carries the new surface.
        repaintIfRebuilt()
    }

    /// Ask the daemon for the screen again if this pane is looking at a surface
    /// nothing has painted into yet. Idempotent: it records what it painted, so
    /// calling it from two places cannot replay twice.
    private func repaintIfRebuilt() {
        guard didAttach, let surface = terminal.surface, surface !== paintedSurface else { return }
        paintedSurface = surface
        Log.debug("repaint \(sessionName)")
        client.repaint()
    }

    /// The second way in, and the reason the first is not enough.
    ///
    /// `attachOrResize` only runs when a viewport report reaches it, and
    /// `InMemoryTerminalSession` drops a report identical to the last one it
    /// saw — a check that survives the surface being replaced, because
    /// `setSurface` does not reset it. A rebuild that happens to lay out in one
    /// pass at exactly the previous geometry therefore reports nothing, and a
    /// pane whose only trigger was that report would stay blank. Two panes
    /// settling over three passes always differ somewhere, which is why this
    /// was not seen; one pane alone in a tab, switched to another tab of the
    /// same shape, is the case that would.
    ///
    /// So the view also asks on appear — but after the debounce window, not
    /// during it. Firing immediately is the original bug: `onAppear` runs
    /// before the representable has made a surface, and the replay it asks for
    /// is dropped exactly like the output was.
    func repaintAfterRebuild() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.repaintIfRebuilt()
        }
    }

    func detach() {
        client.detach()
        isAttached = false
    }

    /// Put text in the session as though it had been typed.
    ///
    /// The bytes go down the same `.input` frame the surface's own keystrokes
    /// use, so the daemon cannot tell the two apart and every other client
    /// watching the session sees it echoed like anything else. Nothing here
    /// appends a newline, and no caller should: the file tree inserts a path
    /// for a person to finish, it does not run commands on their behalf.
    func insert(_ text: String) {
        guard !text.isEmpty else { return }
        client.send(.input, Data(text.utf8))
    }

    /// The visible grid as text — the basis for ⌘K search over panes you aren't
    /// looking at. `zmx history` covers scrollback; this covers the viewport.
    func viewportText() -> String? {
        session.readViewportText()
    }
}

/// Surfaces are expensive and stateful, so they outlive any particular view.
/// One model per session name, created on demand and dropped when the session
/// disappears from the registry.
@MainActor
final class PaneStore: ObservableObject {
    private var models: [String: PaneModel] = [:]

    func model(for sessionName: String) -> PaneModel {
        if let existing = models[sessionName] { return existing }
        let created = PaneModel(sessionName: sessionName)
        models[sessionName] = created
        return created
    }

    /// The model for a session *if it is already talking to the daemon*, and
    /// nil otherwise.
    ///
    /// Deliberately not `model(for:)`, which creates one — an unattached model
    /// drops every `.input` it is given, because `ZmxClient.send` has no socket
    /// until the surface has laid out and reported a viewport. A pane in a
    /// hidden tab and a pane created a moment ago both look like that, so the
    /// answer a caller needs is "can this pane be typed into", not "is there an
    /// object for it". `Reader` takes the other road when this returns nil.
    func attachedModel(for sessionName: String) -> PaneModel? {
        guard let model = models[sessionName], model.isAttached else { return nil }
        return model
    }

    func prune(keeping liveNames: Set<String>) {
        for (name, model) in models where !liveNames.contains(name) {
            model.detach()
            models.removeValue(forKey: name)
        }
    }
}

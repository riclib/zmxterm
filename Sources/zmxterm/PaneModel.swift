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
            do {
                try client.attach(size: size)
                isAttached = true
            } catch {
                gridSummary = "attach failed"
            }
            return
        }
        client.resize(size)
    }

    /// Repaint a surface that was destroyed and rebuilt — switching tabs does
    /// exactly that, while the client underneath stays attached.
    func repaintIfAttached() {
        guard didAttach else { return }
        Log.debug("repaint \(sessionName)")
        client.repaint()
    }

    func detach() {
        client.detach()
        isAttached = false
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

    func prune(keeping liveNames: Set<String>) {
        for (name, model) in models where !liveNames.contains(name) {
            model.detach()
            models.removeValue(forKey: name)
        }
    }
}

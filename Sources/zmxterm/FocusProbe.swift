import AppKit
import GhosttyTerminal
import SwiftUI

/// Puts the keyboard into a pane on demand.
///
/// SwiftUI's focus system is the wrong tool: `TerminalSurfaceView.terminalFocused`
/// is a two-way binding whose push half calls `makeFirstResponder(nil)` on any
/// update where the binding reads false — including the update caused by the
/// click that just focused the pane, which is why focusing used to take two
/// clicks. `terminalFocusOnAppear` is not an escape either; it wraps the same
/// modifier.
///
/// The surface exposes no way to focus itself, so this reaches the `NSView`.
/// It is a zero-sized view planted beside the terminal in the same subtree;
/// when its token changes it walks up to a shared ancestor, finds the sibling
/// terminal, and makes it first responder. One imperative act on request,
/// rather than a binding that re-asserts itself on every render.
struct TerminalFocusProbe: NSViewRepresentable {
    /// Bumped when this pane should take focus. Never fires on 0.
    let token: Int

    func makeNSView(context _: Context) -> ProbeView {
        ProbeView()
    }

    func updateNSView(_ view: ProbeView, context _: Context) {
        guard token != 0, token != view.lastToken else { return }
        view.lastToken = token
        // The surface may not be in a window yet on the pass that creates it.
        DispatchQueue.main.async { view.focusNearestTerminal() }
    }

    final class ProbeView: NSView {
        var lastToken = 0

        func focusNearestTerminal() {
            guard let window else {
                Log.debug("focus probe: no window yet")
                return
            }
            var ancestor: NSView? = superview
            var depth = 0
            while let current = ancestor {
                if let terminal = Self.firstTerminal(in: current) {
                    let granted = window.makeFirstResponder(terminal)
                    Log.debug("focus probe: found terminal \(depth) levels up, granted=\(granted)")
                    return
                }
                ancestor = current.superview
                depth += 1
            }
            Log.debug("focus probe: no terminal found in any ancestor")
        }

        /// Nearest terminal in this subtree, breadth-first so a sibling wins
        /// over something buried deeper in an unrelated branch.
        private static func firstTerminal(in root: NSView) -> NSView? {
            var queue = root.subviews
            var index = 0
            while index < queue.count {
                let view = queue[index]
                index += 1
                if view is AppTerminalView { return view }
                queue.append(contentsOf: view.subviews)
            }
            return nil
        }
    }
}

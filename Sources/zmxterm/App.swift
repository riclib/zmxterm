import AppKit
import SwiftUI

struct ZmxTermApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .frame(minWidth: 900, minHeight: 520)
        }
        .windowStyle(.hiddenTitleBar)
    }
}

/// A SwiftPM executable isn't an app bundle, so nothing sets an activation
/// policy for us and the window would open behind everything, unfocused.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var terminationSignal: DispatchSourceSignal?

    func applicationDidFinishLaunching(_: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // Quitting normally runs applicationWillTerminate, but a SIGTERM —
        // `pkill`, a stopped dev run — does not, and every client we fail to
        // detach lingers on its daemon holding a vote on the session's size.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            ZmxClient.detachAll()
            exit(0)
        }
        source.resume()
        terminationSignal = source
    }

    func applicationWillTerminate(_: Notification) {
        ZmxClient.detachAll()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool { true }
}

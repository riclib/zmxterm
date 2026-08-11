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
        installMenu()

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

    /// A SwiftPM executable has no menu bar, and ⌘Q lives on the standard Quit
    /// item — without one the app can only be quit by closing its window.
    ///
    /// No Edit menu on purpose. ⌘C and ⌘V are Ghostty keybinds handled inside
    /// the surface; menu items claiming those key equivalents would intercept
    /// them first and send `copy:`/`paste:` to a responder that may not
    /// implement them, turning working shortcuts into dead ones.
    private func installMenu() {
        let application = NSMenu()
        let applicationItem = NSMenuItem()
        let submenu = NSMenu()

        submenu.addItem(
            withTitle: "About zmxterm",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        submenu.addItem(.separator())
        submenu.addItem(
            withTitle: "Hide zmxterm",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        let hideOthers = NSMenuItem(
            title: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        submenu.addItem(hideOthers)
        submenu.addItem(.separator())
        submenu.addItem(
            withTitle: "Quit zmxterm",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        applicationItem.submenu = submenu
        application.addItem(applicationItem)
        NSApp.mainMenu = application
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool { true }
}

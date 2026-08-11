import Foundation

if CommandLine.arguments.contains("--selftest") {
    exit(SelfTest.run())
}

/// `zmxterm [tab]` — open straight to a named tab. Without one the app shows
/// whichever tab sorts first, which is fine for a single-project machine and
/// wrong the moment you have a live team you'd rather not attach to by accident.
enum AppOptions {
    static let initialTab: String? = CommandLine.arguments.dropFirst().first { !$0.hasPrefix("-") }
}

ZmxTermApp.main()

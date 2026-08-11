import Foundation

/// Placeholder names, for the two things that need different kinds of name.
///
/// A tab is somewhere you return to and refer to out loud — "it's in zaphod" —
/// so a memorable name earns its keep, and `zsm` shows the same list this app
/// does, which means the list may as well repay reading. A pane inside a tab is
/// positional and disposable: `shell-1` says what it is, where a second
/// memorable name would just be two names for one thing.
///
/// Lowercase and alphanumeric to stay inside zmx's name and label charset.
enum SessionNames {
    static let pool = [
        "arthur", "ford", "zaphod", "trillian", "marvin", "slartibartfast",
        "deepthought", "eddie", "fenchurch", "agrajag", "zarniwoop", "wowbagger",
        "jeltz", "hotblack", "humma", "colin", "random", "frankie", "benjy",
        "lunkwill", "fook", "garkbit", "gag", "prak", "roosta", "vroomfondel",
        "majikthise", "krikkit", "magrathea", "betelgeuse", "damogran",
        "vogsphere", "kakrafoon", "santraginus", "babelfish", "gargleblaster",
        "bugblatter", "dentrassi", "hoopy", "frood", "petunias", "milliways",
        "brantisvogan", "traal", "haggunenon", "silastic", "poghril",
    ]

    /// A tab name: the first unused character, then numbered rounds once a
    /// remarkable number of tabs are open at the same time.
    static func nextTab(avoiding taken: Set<String>) -> String {
        for name in pool where !taken.contains(name) { return name }
        var round = 2
        while true {
            for name in pool where !taken.contains("\(name)\(round)") { return "\(name)\(round)" }
            round += 1
        }
    }

    /// A pane name: `<tab>.shell-N`, numbered within its tab. Prefixing by tab
    /// means the counter never has to be global.
    static func nextPane(in tab: String, avoiding taken: Set<String>) -> String {
        var index = 1
        while taken.contains("\(tab).shell-\(index)") { index += 1 }
        return "\(tab).shell-\(index)"
    }
}

import Foundation

/// The pane you keep documents in.
///
/// A reader is **a shell session running a viewer**, marked `reader=1` — not a
/// session whose process *is* the viewer, and not a native panel. That
/// distinction is the whole feature. With a shell underneath, the viewer can be
/// stopped and started again on a different file while the pane keeps its name,
/// position, size, scrollback and labels; a session whose process was the viewer
/// would have to be killed and recreated for every document, losing all of it.
///
/// It also keeps the one rule in `CLAUDE.md`. A reader is a zmx session like any
/// other, so `zsm` sees it, it survives the app quitting, and it restores itself
/// without the app remembering anything. The label is a bare flag, which fits
/// zmx's `[A-Za-z0-9._-]` charset — the path, which could never live in a label,
/// lives in argv where a path belongs.
///
/// **What a reader is, precisely, is a pane whose job is to show a thing, where
/// the thing's type picks the command.** Markdown was only the first type. A
/// list of rules is matched against the file, first match wins, and everything
/// downstream of that lookup — the swap, the quit-then-signal, the refusal, the
/// tab scoping — is unchanged by it.
///
/// Everything here is a pure function of (rules, what is running, path) so
/// `--selftest` can settle the interesting arguments — which rule matches, what
/// gets typed, when the viewer is quit first, when the pane is refused —
/// without a daemon, a window, or a viewer installed.
enum Reader {
    // MARK: - A rule

    /// One line of the viewer list: what it matches, what it runs, how it stops.
    ///
    /// The quit key belongs here rather than to the app, and that is not a
    /// detail. `q` quits `mdv` and `bat`'s pager; a `tail -f` has no quit key at
    /// all and needs `^C`. One setting for every viewer could only be right for
    /// some of them.
    struct Rule: Equatable {
        /// Globs, matched against the file's *name* rather than its whole path,
        /// case-insensitively. A rule with several patterns is one rule — `*.log`
        /// and `*.jsonl` are the same decision written once.
        var patterns: [String]

        /// The command line, with `{path}` where the file goes. It may appear
        /// more than once, or not at all: a command with no `{path}` gets the
        /// file appended, which is what every `readerCommand` ever written for
        /// #20 assumed and costs nothing to keep true.
        var command: String

        /// What makes the viewer exit — `q`, or `^C` for something that has no
        /// quit key. Empty means "this one stops for nothing", and the swap goes
        /// straight to the signal rather than typing a letter into something
        /// that will only display it.
        var quitKey: String

        init(patterns: [String], command: String, quitKey: String = "q") {
            self.patterns = patterns
            self.command = command
            self.quitKey = quitKey
        }

        /// Whether this rule claims the file. `fnmatch` rather than a hand-rolled
        /// matcher because a glob is a solved problem and `*.log` should mean
        /// what it means in a shell.
        func matches(_ path: String) -> Bool {
            let name = ((path as NSString).lastPathComponent as String).lowercased()
            return patterns.contains { pattern in
                fnmatch(pattern.lowercased(), name, 0) == 0
            }
        }

        /// Every binary the rule needs, one per pipeline stage.
        ///
        /// A pipeline is not a viewer: `tail -f {path} | hl -P` runs two
        /// programs and is only usable if both are there. Checking the first
        /// would fall through to nothing when `humanlog` is the missing half,
        /// and a pane opening onto `humanlog: command not found` is the empty
        /// reader this was meant to avoid.
        var executables: [String] {
            command.split(separator: "|").map { Reader.executable(of: String($0)) }
                .filter { !$0.isEmpty }
        }

        /// What to call this rule's viewer in a sentence to a human. Not an
        /// identity: identity is the pid we watched start — see `plan`.
        var viewer: String { Reader.viewer(of: command) }

        /// The command line for a document. The path is quoted rather than
        /// escaped because it is going into a shell — `FileTree.shellQuoted` is
        /// the same rule the file tree inserts paths with, so a path with a
        /// space in it cannot arrive as two different strings depending on which
        /// gesture sent it. Absolute, not relative: the reader's shell is not
        /// necessarily sitting in the directory the tree is rooted at.
        func commandLine(opening path: String) -> String {
            let quoted = FileTree.shellQuoted(path)
            guard command.contains(Reader.pathPlaceholder) else { return command + " " + quoted }
            return command.replacingOccurrences(of: Reader.pathPlaceholder, with: quoted)
        }
    }

    static let pathPlaceholder = "{path}"

    // MARK: - The list

    /// The viewers this build knows about when nobody has said otherwise.
    ///
    /// It is written as config text rather than as Swift values on purpose: the
    /// defaults and the file a user writes go through exactly the same parser,
    /// so a format the defaults can express is a format the file can express,
    /// and there is no second code path to keep honest.
    ///
    /// Two rules name the same patterns twice, which looks redundant and is the
    /// point: `mdv` is the viewer this was designed against, `glow` renders the
    /// same documents, and a machine with only one of them installed falls
    /// through to the one it has. Same for `bat` and `less` at the bottom, and
    /// for logs, where `hl` formats structured lines and `tail -f` is what every
    /// machine has.
    ///
    /// The log rules follow a file directly rather than piping `tail` into a
    /// formatter. One process instead of two is not a style preference here:
    /// identity is the pid of what we watched start, and a pipeline's foreground
    /// process is whichever half `ps` happens to list first. `hl` needs `-P` for
    /// this, because it pages by default and a pager would sit on a live follow
    /// rather than streaming it.
    static let builtinConfig = """
    # patterns              command
    *.md *.markdown         mdv --watch {path}
    *.md *.markdown         glow -p {path}
    *.log *.jsonl *.ndjson  quit=^C  hl -P --follow {path}
    *.log *.jsonl *.ndjson  quit=^C  tail -f {path}
    *                       bat --paging=always {path}
    *                       less {path}
    """

    static let builtin: [Rule] = parse(builtinConfig).rules

    /// Where a user's list lives. Ghostty's own search order, minus the
    /// Application Support path, because this file is ours and `~/.config` is
    /// where a text file full of shell commands belongs.
    static var configPaths: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var paths: [String] = []
        if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            paths.append("\(xdg)/zmxterm/viewers.conf")
        }
        paths.append("\(home)/.config/zmxterm/viewers.conf")
        return paths
    }

    /// The file the app would read, or the first candidate if there is none —
    /// which is the one to name in a message telling somebody where to write it.
    static var configPath: String {
        let candidates = configPaths
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
            ?? candidates.last
            ?? "~/.config/zmxterm/viewers.conf"
    }

    static let commandDefaultsKey = "readerCommand"
    static let quitKeyDefaultsKey = "readerQuitKey"

    /// A parsed list, and whatever was wrong with it.
    ///
    /// Problems are carried rather than thrown because a list that is half
    /// wrong is still mostly right, and the half that parsed is more use than a
    /// diagnostic. See `parse` for why that is not a matter of taste here.
    struct Parsed: Equatable {
        var rules: [Rule]
        var problems: [String]

        /// One sentence naming the file and the first thing wrong with it, or
        /// nil. This is what the app has to *say*, and it says it: a config that
        /// was silently ignored is indistinguishable from a config that did not
        /// work, and the second costs an afternoon.
        var problem: String? {
            guard let first = problems.first else { return nil }
            let rest = problems.count > 1 ? " (and \(problems.count - 1) more)" : ""
            return first + rest
        }
    }

    /// The rules in force, read at the moment somebody opens a document.
    ///
    /// Deliberately not cached and deliberately not watched. `TerminalConfig`
    /// needs a watcher because libghostty holds the parsed config and has to be
    /// handed a new one; nothing holds these, so reading the file per gesture —
    /// a few hundred bytes, once per menu click — makes an edit take effect
    /// immediately with no machinery at all. What *is* cached is the login PATH
    /// the rules are checked against, which is the expensive half.
    static var rules: Parsed { load() }

    static func load(
        path: String? = configPaths.first(where: { FileManager.default.fileExists(atPath: $0) }),
        command: String? = UserDefaults.standard.string(forKey: commandDefaultsKey),
        quitKey: String? = UserDefaults.standard.string(forKey: quitKeyDefaultsKey)
    ) -> Parsed {
        if let path, let text = try? String(contentsOfFile: path, encoding: .utf8) {
            var parsed = parse(text)
            // **A file that yielded nothing falls back to the built-ins, and
            // says so.** Note what this is not: libghostty rejects its *entire*
            // config over one bad key, which is documented in `CLAUDE.md` as a
            // failure mode that cost hours — one unresolvable line and every
            // other setting in the file is gone. So a bad line here loses that
            // line and nothing else, and the fallback is for a file that has no
            // usable rule left at all.
            guard parsed.rules.isEmpty else { return parsed }
            // In front of the line-by-line complaints rather than after them:
            // the consequence is the part somebody has to hear, and the first
            // problem is the one a one-line message gets to show.
            parsed.problems.insert(
                "\(path) has no usable viewer rules, so the built-in defaults are in use.",
                at: 0
            )
            return Parsed(rules: builtin, problems: parsed.problems)
        }

        // #20's single viewer, still honoured when there is no file. It was
        // documented, somebody wrote it, and it means exactly what an
        // unconditional rule at the top of the list means. A file supersedes it
        // rather than merging with it: two places to look for one answer is one
        // too many, and the file is the one with room to say more.
        let legacy = command?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !legacy.isEmpty else { return Parsed(rules: builtin, problems: []) }
        return Parsed(
            rules: [Rule(patterns: ["*"], command: legacy, quitKey: quitKey ?? "q")] + builtin,
            problems: []
        )
    }

    // MARK: - Reading the file

    /// One rule per line: patterns, then the command.
    ///
    ///     *.md *.markdown         mdv --watch {path}
    ///     *.log *.jsonl  quit=^C  tail -f {path} | humanlog
    ///     *                       bat --paging=always {path}
    ///
    /// The patterns are separated from the command by **two or more spaces, or a
    /// tab** — the gap is the delimiter, which is why the example above lines up
    /// in columns and why a command can contain single spaces, pipes, quotes and
    /// anything else a shell reads without needing to be quoted. A line with no
    /// such gap is read as one pattern and a command, so a single-spaced
    /// `*.md mdv --watch {path}` still does what it looks like.
    ///
    /// `quit=` in front of the command is the rule's stop method rather than
    /// part of it, and is the one word treated that way: `TERM=xterm-kitty mdv`
    /// is still an environment assignment handed to the shell, because that is
    /// the documented workaround for #22 and somebody has it in their config.
    ///
    /// Blank lines and `#` comments are skipped. Every other line that cannot be
    /// read is skipped *with a complaint* — the file keeps the rules that
    /// parsed. One bad line taking the whole file with it is the libghostty
    /// failure mode in `CLAUDE.md`, and reproducing it deliberately would be
    /// hard to defend.
    static func parse(_ text: String) -> Parsed {
        var rules: [Rule] = []
        var problems: [String] = []

        for (index, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let number = index + 1

            guard let (patterns, remainder) = split(line) else {
                problems.append(
                    line.contains(" ")
                        ? "line \(number): \"\(line)\" is not a rule — put two or more spaces "
                        + "between the patterns and the command."
                        : "line \(number): \"\(line)\" names patterns but no command."
                )
                continue
            }
            var command = remainder
            var quitKey = "q"
            if let value = leadingOption(named: "quit", in: &command) { quitKey = controlCharacters(value) }
            guard !command.isEmpty else {
                problems.append("line \(number): \"\(line)\" names patterns but no command.")
                continue
            }
            guard !executable(of: command).isEmpty else {
                problems.append("line \(number): \"\(command)\" runs no program.")
                continue
            }
            rules.append(Rule(patterns: patterns, command: command, quitKey: quitKey))
        }
        return Parsed(rules: rules, problems: problems)
    }

    /// The patterns and the rest, split at the first run of two or more spaces
    /// or a tab — or, failing that, after a first word that is unmistakably a
    /// glob.
    ///
    /// The second half is why this is not simply "split on the gap". Somebody
    /// will write `*.md mdv --watch {path}` with one space, and a rule that
    /// silently did nothing because of a space is a bad afternoon. But the
    /// forgiveness has to stop somewhere, or every line of English in a file is
    /// a rule matching a file called `this` — which is exactly how a file full
    /// of nonsense would parse cleanly and the fallback to the built-in
    /// defaults would never fire. A word containing `*`, `?` or `[` is a
    /// pattern and nothing else; anything else needs the columns.
    private static func split(_ line: String) -> ([String], String)? {
        var head = line
        var tail = ""
        if let gap = line.range(of: "[ ]{2,}|\t", options: .regularExpression) {
            head = String(line[line.startIndex ..< gap.lowerBound])
            tail = String(line[gap.upperBound...]).trimmingCharacters(in: .whitespaces)
        } else if let space = line.firstIndex(of: " "),
                  line[line.startIndex ..< space].contains(where: { "*?[".contains($0) })
        {
            head = String(line[line.startIndex ..< space])
            tail = String(line[line.index(after: space)...]).trimmingCharacters(in: .whitespaces)
        }
        let patterns = head.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard !patterns.isEmpty, !tail.isEmpty else { return nil }
        return (patterns, tail)
    }

    /// Take `name=value` off the front of a command if it is there. The value
    /// may be empty — `quit=` is a real answer meaning "nothing stops this one,
    /// signal it".
    private static func leadingOption(named name: String, in command: inout String) -> String? {
        let prefix = name + "="
        guard command.hasPrefix(prefix) else { return nil }
        let rest = command.dropFirst(prefix.count)
        let end = rest.firstIndex(of: " ") ?? rest.endIndex
        let value = String(rest[rest.startIndex ..< end])
        command = String(rest[end...]).trimmingCharacters(in: .whitespaces)
        return value
    }

    /// `^C` in a text file is two characters; what stops a `tail` is one byte.
    ///
    /// Caret notation because that is how everyone writes control characters in
    /// prose and in `stty -a`, and because a config file cannot hold the byte
    /// itself without an editor that will eat it.
    static func controlCharacters(_ text: String) -> String {
        var out = ""
        let characters = Array(text)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            // `^@` through `^_`, which is every control character there is:
            // `^C` is 3, `^U` is 21, `^[` is escape. Anything else after a caret
            // is a caret and that character, because a viewer whose quit key is
            // literally `^` is likelier than a config that meant nothing.
            if character == "^", index + 1 < characters.count,
               let scalar = String(characters[index + 1]).uppercased().unicodeScalars.first,
               scalar.value >= 64, scalar.value <= 95,
               let control = Unicode.Scalar(scalar.value - 64)
            {
                out.unicodeScalars.append(control)
                index += 2
                continue
            }
            out.append(character)
            index += 1
        }
        return out
    }

    // MARK: - Which rule

    /// What matching a file came to.
    enum Match: Equatable {
        /// This rule, whose viewers are all installed.
        case run(Rule)
        /// Rules matched and not one of them can run here. Names what was tried.
        case missing([String])
        /// Nothing in the list claims this file at all. Spelled `unmatched`
        /// rather than `none`, which every reader of a switch would have to
        /// stop and check was not `Optional.none`.
        case unmatched
    }

    /// First match wins, and **a rule whose viewer is not installed falls
    /// through to the next match.**
    ///
    /// That fallthrough is the difference between a list and a lookup table. No
    /// `mdv` on the machine means a `.md` opens in `bat` rather than refusing:
    /// degrading to a worse viewer beats degrading to nothing, and the person
    /// who wanted to read a file wanted to read the file. It also makes the
    /// list writable without knowing what any particular machine has — name the
    /// viewer you want first and the one you will settle for after it.
    static func match(
        path: String,
        in rules: [Rule],
        isInstalled: (Rule) -> Bool = { Reader.isInstalled($0) }
    ) -> Match {
        var tried: [String] = []
        var matched = false
        for rule in rules where rule.matches(path) {
            matched = true
            if isInstalled(rule) { return .run(rule) }
            tried.append(rule.viewer)
        }
        return matched ? .missing(tried) : .unmatched
    }

    // MARK: - Naming a binary

    /// The binary in a command line, skipping leading `NAME=value` assignments.
    ///
    /// The assignments are not hypothetical: `TERM=xterm-kitty mdv --watch` is
    /// the documented workaround for #22, so somebody will configure it. Taking
    /// the first word blindly would name the viewer `TERM=xterm-kitty`, and then
    /// nothing would ever be found installed.
    static func executable(of command: String) -> String {
        for word in command.split(separator: " ", omittingEmptySubsequences: true) {
            // An assignment is `NAME=…` with nothing path-like before the `=`.
            if let equals = word.firstIndex(of: "="), !word[..<equals].contains("/") { continue }
            return String(word)
        }
        return ""
    }

    /// The executable reduced to a basename, which is how a human refers to it.
    ///
    /// It used to be how a *running* viewer was recognised, by comparing it to
    /// what `ps` reports, and that comparison could not survive a pipeline.
    /// Both stages of `tail -f {path} | humanlog` are children of the pane's
    /// shell, so `ForegroundProcess` reports whichever it reaches first —
    /// measured as `tail` here, which is the rule's first word and would have
    /// matched by luck; `humanlog` is what it reports the day the pids come out
    /// the other way round. A name that depends on which half of a pipeline the
    /// scan listed first cannot decide whether a pane is ours. Recognition is by
    /// pid now and this is only ever a word in a sentence.
    static func viewer(of command: String) -> String {
        (executable(of: command) as NSString).lastPathComponent
    }

    // MARK: - Which pane

    /// The reader of one tab, if it has one.
    ///
    /// Scoped to a tab rather than to the whole machine, and that is the useful
    /// scope: a document opened from a file tree belongs beside the pane it was
    /// opened from, and sending it to a reader in a tab you are not looking at
    /// would be a document that opens nowhere. A tab with two panes marked by
    /// hand resolves to the first in the order the registry sorts them, which is
    /// stable, rather than to whichever `zmx list` happened to report first.
    static func pane(among panes: [ZmxSession], tab: String) -> ZmxSession? {
        panes.first { $0.tab == tab && $0.isReader }
    }

    // MARK: - What gets typed

    /// The bytes that actually reach the pty, which is the command line with a
    /// `^U` in front and a carriage return behind.
    ///
    /// The return is the one place in this app where a trailing newline is
    /// wanted — the file tree inserts a path for a person to finish, this runs a
    /// viewer — and `\r` rather than `\n` because that is what the Return key
    /// sends.
    ///
    /// `^U` kills whatever is on the shell's line first, and it is not
    /// tidiness. Whatever stopped the last viewer left something on the prompt:
    /// a `q` the viewer ignored and echoed, or the `^C` a `tail` needed. Without
    /// the kill the next command arrives as `qmdv --watch …`. It is `^U` rather
    /// than another `^C` because SIGINT flushes the tty's input queue, so a `^C`
    /// sent in the same write would take the command with it — which is why the
    /// stop and this are always two separate sends, whatever the stop is.
    static func keystrokes(_ rule: Rule, opening path: String) -> String {
        "\u{15}" + rule.commandLine(opening: path) + "\r"
    }

    // MARK: - What opening a document requires

    /// Whether the viewer has to be stopped before the next one can start, given
    /// what is running in the reader now.
    enum Plan: Equatable {
        /// Nothing but the login shell: type the command.
        case start
        /// The viewer is up on another document: stop it, then type.
        case swap
        /// Something else entirely is running in there. Refused, with the name.
        case busy(String)
    }

    /// A pane marked `reader=1` is still a shell somebody can use, and `vim` or
    /// a build running in it is not a viewer to be stopped and typed over. So an
    /// unrecognised foreground process refuses rather than guessing.
    ///
    /// **Recognition is by pid: the one we watched start.** The name it answers
    /// to cannot do this job, for two reasons that arrive together with a rule
    /// list. A pipeline is several processes under one shell and the name that
    /// comes back is whichever the scan reached first, which is not a fact about
    /// the rule that started it — see `viewer(of:)`. And a `tail -f` never ends,
    /// so a reader showing a log would
    /// be permanently "busy" by any rule that asks whether a viewer is still
    /// running — swapping to a second log would be refused forever. A pid
    /// answers both: if the foreground process is the one we started, it is ours
    /// to stop, whatever it is called and however long it runs.
    ///
    /// The memory is in-process and does not survive a restart. That is fine and
    /// worth stating: afterwards an unrecognised process is treated as somebody
    /// else's and the pane refuses, which is the safe direction to be wrong in —
    /// the cost is a `q` you type yourself, against typing a quit key into
    /// somebody's editor. It is emphatically not persisted: it is not session
    /// state, `zsm` has no opinion about it, and a pid outlives nothing.
    static func plan(foreground: ForegroundProcess.Running?, started: pid_t?) -> Plan {
        guard let foreground else { return .start }
        guard let started, foreground.pid == started else { return .busy(foreground.name) }
        return .swap
    }

    /// The foreground pid we watched start in each reader, by session name.
    ///
    /// A dictionary rather than a field on the pane because a pane is a
    /// `ZmxSession` — a value read back from the daemon, which knows nothing
    /// about this and should not.
    ///
    /// Nothing removes an entry when a session ends, and nothing needs to: an
    /// entry is a pid that will not be the foreground process of anything else,
    /// so a stale one reads as "not ours" exactly like no entry at all, and
    /// there is one per reader pane ever opened.
    @MainActor static var startedViewers: [String: pid_t] = [:]

    // MARK: - Is the viewer even there

    /// The PATH a pane will actually have, asked of the shell once.
    ///
    /// A GUI process inherits no login environment — the same fact that makes
    /// `Zmx.executable` a list of candidate paths — so a viewer in
    /// `~/.local/bin` is invisible to us and perfectly visible to the session.
    /// Asking the shell is the only answer that matches what will happen.
    ///
    /// **It has to be an *interactive* login shell, and that is the whole bug
    /// this replaced.** `zsh -lc` is a login shell that is not interactive, so
    /// it reads `.zprofile` and skips `.zshrc` — and `.zshrc` is where a great
    /// many people, including the author, actually build their PATH. The check
    /// reported `mdv` missing while the pane it was about to create could run
    /// it, because `zmx attach` spawns a login shell **on a pty**, which is
    /// interactive and does read `.zshrc`. Modelling the pane's shell means
    /// matching both flags, not one.
    ///
    /// Resolved once and cached, because an interactive shell is not cheap:
    /// ~525ms here against ~35ms for the non-interactive one, most of it
    /// somebody's prompt framework. Once, lazily, is affordable; a rule list
    /// names several viewers and a pipeline names two binaries in one rule, so
    /// per lookup it would not be.
    static let loginPath: [String] = {
        let shell = ShellIntegration.loginShell()
        // `-i` as well as `-l`; see above. `printf` rather than `echo` so a
        // PATH containing a backslash survives.
        let raw = ForegroundProcess.shell(shell, ["-ilc", #"printf %s "$PATH""#])
        let entries = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ":").map(String.init).filter { !$0.isEmpty }
        Log.debug("login PATH: \(entries.count) entries via \(shell)")
        // A shell that answered nothing leaves us worse off than the
        // environment we already have, so fall back rather than resolving
        // nothing at all.
        guard !entries.isEmpty else {
            return (ProcessInfo.processInfo.environment["PATH"] ?? "")
                .split(separator: ":").map(String.init)
        }
        return entries
    }()

    /// A rule can run here only if every stage of it can.
    static func isInstalled(_ rule: Rule, searching path: [String] = Reader.loginPath) -> Bool {
        let named = rule.executables
        guard !named.isEmpty else { return false }
        return named.allSatisfy { isInstalled(executable: $0, searching: path) }
    }

    /// The executable as written, not the basename `viewer` reduces it to.
    ///
    /// The distinction only shows up when someone names a viewer by path.
    /// `viewer` is deliberately a basename, because that is what a human calls
    /// it — but that makes it the wrong thing to ask "is this installed" about.
    /// Asked of the basename, a configured `/Users/me/bin/mdv` gets looked up on
    /// the PATH: it can report missing while the configured file is right there,
    /// or report present because a *different* `mdv` is on the PATH. Two
    /// questions, two functions.
    static func isInstalled(executable named: String, searching path: [String] = Reader.loginPath) -> Bool {
        guard !named.isEmpty else { return false }
        // A path is checkable without asking anybody.
        if named.contains("/") { return FileManager.default.isExecutableFile(atPath: named) }
        return path.contains {
            FileManager.default.isExecutableFile(atPath: $0 + "/" + named)
        }
    }

    // MARK: - Timings

    /// How long a viewer gets to act on its own stop key before it is signalled.
    /// Measured: `mdv` is gone in well under half of this.
    static let quitGrace: TimeInterval = 0.5
    /// And how long after a signal before the shell is typed into.
    static let signalGrace: TimeInterval = 0.4
    /// How long a freshly created session gets before its shell is typed into.
    /// The daemon exists by the time `createSession` returns — it waits for the
    /// client to exit — but the login shell inside it is still starting.
    static let startupGrace: TimeInterval = 0.6
    /// And how long after typing before we ask which process that started.
    ///
    /// Generous, because being late is only wrong in the direction that refuses:
    /// a viewer we failed to see start is a viewer we will not offer to stop,
    /// and the human types `q` themselves. Being early and recording nothing has
    /// the same cost, so there is no case for cutting this fine.
    static let observeGrace: TimeInterval = 1.0

    // MARK: - What happened

    /// The result of asking for a document, in the caller's terms rather than
    /// in labels, so the panel that asked can say why nothing opened.
    enum Outcome: Equatable {
        case opened(pane: String)
        case busy(pane: String, running: String)
        /// Rules matched the file and none of their viewers is installed.
        case missingViewer([String])
        /// No rule matched at all. Names the file, since the rules are globs.
        case noRule(String)
        /// No pane to split, so there is nowhere to put a reader.
        case noPane

        /// Nil when it worked. A sentence otherwise, naming the thing to fix.
        var problem: String? {
            switch self {
            case .opened:
                nil
            case let .busy(pane, running):
                "\(pane) is running \(running). Quit it first, or open the document in another reader."
            case let .missingViewer(tried):
                """
                \(tried.isEmpty ? "The viewer" : tried.joined(separator: ", ")) \
                \(tried.count == 1 ? "is" : "are") not installed, or not on the login shell's PATH. \
                Install one, or add a rule to \(Reader.configPath).
                """
            case let .noRule(file):
                "No viewer rule matches \((file as NSString).lastPathComponent). Add one to \(Reader.configPath)."
            case .noPane:
                "There is no pane here to open a reader beside."
            }
        }
    }
}

// MARK: - Opening a document

@MainActor
extension ZmxRegistry {
    /// Open `path` in `tab`'s reader, making one if the tab has none.
    ///
    /// "Stable panel" is the whole design: a second document replaces what the
    /// reader is showing rather than building a second reader, so this prefers
    /// an existing pane over creating one and only ever splits when there is
    /// nothing marked `reader=1` in the tab.
    ///
    /// The rule is chosen first, before any of that, because it is the one part
    /// that can fail for a reason the human can act on — no rule for a `.xyz`,
    /// or a rule whose viewer nobody installed. It is also the only new thing
    /// here: everything below the lookup is #20's machinery unchanged.
    ///
    /// Returns immediately with what it decided. The typing that follows is
    /// spread over a few hundred milliseconds — a viewer needs a beat to act on
    /// its quit key, a new session needs one to start its shell — and none of it
    /// changes the answer to "did this open, and if not why not".
    @discardableResult
    func openInReader(
        path: String,
        tab: String,
        near focused: String?,
        store: PaneStore,
        rules: [Reader.Rule] = Reader.rules.rules
    ) -> Reader.Outcome {
        let rule: Reader.Rule
        switch Reader.match(path: path, in: rules) {
        case let .run(matched): rule = matched
        case let .missing(tried): return .missingViewer(tried)
        case .unmatched: return .noRule(path)
        }
        Log.debug("reader rule for \(path): \(rule.patterns.joined(separator: " ")) → \(rule.command)")
        let keystrokes = Reader.keystrokes(rule, opening: path)

        if let reader = Reader.pane(among: sessions, tab: tab) {
            // Resolved now rather than read off the session's `command`, which
            // the registry fills in on a two-second poll: between the poll and
            // the click, the viewer may have been quit by hand.
            let running = ForegroundProcess.running(sessionPID: reader.pid)
            switch Reader.plan(foreground: running, started: Reader.startedViewers[reader.name]) {
            case let .busy(name):
                Log.debug("reader \(reader.name): refusing, \(name) is running")
                return .busy(pane: reader.name, running: name)

            case .start:
                type(keystrokes, into: reader.name, store: store)
                return .opened(pane: reader.name)

            case .swap:
                // Two sends, never one. `^C` is a legitimate stop method now
                // that a rule can run a `tail`, and SIGINT flushes the tty's
                // input queue — the command line that follows it has to be in a
                // later write or it goes with it.
                if !rule.quitKey.isEmpty {
                    send(rule.quitKey, to: reader.name, store: store)
                }
                // The fallback the design asked for: a viewer that ignores its
                // own stop key must not leave the pane wedged. Only the process
                // we watched start is signalled — if the pid changed, the viewer
                // did exit and something else is there now, and that is not ours
                // to kill. A pipeline is signalled a stage at a time and needs
                // only one: kill the reader and the writer gets SIGPIPE, kill
                // the writer and the reader gets EOF.
                DispatchQueue.main.asyncAfter(deadline: .now() + Reader.quitGrace) { [weak self] in
                    guard let self else { return }
                    let stubborn = ForegroundProcess.running(sessionPID: reader.pid)
                    guard let stubborn, stubborn.pid == running?.pid else {
                        type(keystrokes, into: reader.name, store: store)
                        return
                    }
                    Log.notice("reader \(reader.name): \(stubborn.name) ignored its stop key, signalling")
                    // Spelled with its module: `ZmxRegistry.kill(_:)` destroys
                    // a whole session, and an unqualified `kill` in an
                    // extension of it resolves to that rather than to the
                    // signal. The compiler catches it, which is luck.
                    Darwin.kill(stubborn.pid, SIGTERM)
                    DispatchQueue.main.asyncAfter(deadline: .now() + Reader.signalGrace) { [weak self] in
                        self?.type(keystrokes, into: reader.name, store: store)
                    }
                }
                return .opened(pane: reader.name)
            }
        }

        guard let anchor = focused ?? sessions.first(where: { $0.tab == tab })?.name else {
            return .noPane
        }
        guard let created = createReader(near: anchor) else { return .noPane }
        DispatchQueue.main.asyncAfter(deadline: .now() + Reader.startupGrace) { [weak self] in
            self?.type(keystrokes, into: created, store: store)
        }
        return .opened(pane: created)
    }

    /// Type a command line into a reader and then look at what it started.
    ///
    /// The looking is the whole of the pid memory: a moment after the shell has
    /// been given a command, whatever is in the foreground is what that command
    /// started, and it is ours to stop next time. Nothing else in the app cares
    /// which process a pane is running — the icon rule asks the same question of
    /// every pane on a poll — so this is deliberately only done on the path that
    /// started something.
    private func type(_ keystrokes: String, into session: String, store: PaneStore) {
        send(keystrokes, to: session, store: store)
        DispatchQueue.main.asyncAfter(deadline: .now() + Reader.observeGrace) { [weak self] in
            guard let self, let pane = sessions.first(where: { $0.name == session }) else { return }
            let started = ForegroundProcess.running(sessionPID: pane.pid)
            Reader.startedViewers[session] = started?.pid
            Log.debug("reader \(session): started \(started?.name ?? "nothing") pid \(started?.pid ?? 0)")
        }
    }

    /// A reader is an ordinary split that carries one more label, so it is the
    /// same placement, the same `ephemeral=1`, and the same everything else.
    ///
    /// Disposable is right even for a pane somebody means to keep: the reaper
    /// vetoes on a session running something other than a login shell, so a
    /// reader with a document open in it is never a candidate, and one sitting
    /// at an idle prompt for twelve hours is exactly the pane that should go.
    @discardableResult
    func createReader(near focused: String, axis: SplitAxis = .horizontal) -> String? {
        guard let created = split(pane: focused, axis: axis) else { return nil }
        Zmx.run(["set", created, "reader=1"])
        refresh()
        return created
    }

    /// Designate a pane, or stop. The label is the whole implementation, which
    /// is the test for whether a feature belongs in this app: `zmx set <name>
    /// reader=1` from any shell does exactly this.
    func setReader(_ isReader: Bool, on session: String) {
        Zmx.run(["set", session, isReader ? "reader=1" : "reader="])
        refresh()
    }

    /// Put keystrokes in a session, whether or not it is on screen.
    ///
    /// The attached path is the honest one: the bytes go down the same `.input`
    /// frame the surface's own keystrokes use, so the daemon cannot tell them
    /// from typing. But a pane in a hidden tab has no surface, and a pane
    /// created half a second ago has not attached yet, and both of those are
    /// ordinary here — the reader may well be created by this very call. `zmx
    /// send` is the same input from the other side of the socket, and it works
    /// on a session nobody is watching.
    private func send(_ text: String, to session: String, store: PaneStore) {
        if let model = store.attachedModel(for: session) {
            model.insert(text)
        } else {
            Zmx.run(["send", session, text])
        }
    }
}

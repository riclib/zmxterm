import Combine
import Foundation

/// One entry in a directory listing.
///
/// `path` is the literal path — what is shown and what gets inserted into a
/// pane. `resolvedPath` is the same thing with symlinks followed, and exists
/// only so that descending can refuse to walk in circles: a directory whose
/// resolved path is already an ancestor of itself is a loop, and `ls -R` down
/// one of those never finishes.
struct FileEntry: Identifiable, Equatable, Sendable {
    let path: String
    let name: String
    let isDirectory: Bool
    let resolvedPath: String

    var id: String { path }

    /// Files never need a resolved path — nothing descends into them — so the
    /// listing skips the `realpath` call and this fills the field in.
    init(path: String, name: String, isDirectory: Bool, resolvedPath: String? = nil) {
        self.path = path
        self.name = name
        self.isDirectory = isDirectory
        self.resolvedPath = resolvedPath ?? path
    }
}

/// A row of the flattened tree: an entry plus everything the view needs to draw
/// it. Produced by `FileTree.rows`, which is where the shape of the tree is
/// decided — see there for why the flattening is a function rather than a
/// recursive view.
struct FileRow: Identifiable, Equatable {
    let entry: FileEntry
    /// Nesting depth below the root, which is not itself a row: the root's path
    /// is the panel's header, not something you can collapse.
    let depth: Int
    let isExpanded: Bool
    /// Expanded, but its listing has not come back yet.
    let isLoading: Bool
    /// False for files, and for a directory that would loop back on itself.
    let canExpand: Bool

    var id: String { entry.path }
}

/// The rules of the file tree, with no view and no filesystem attached to any
/// of the interesting ones.
///
/// Everything a person could argue about — which directory the tree roots at,
/// what order a listing comes out in, what text a double-click puts in a pane,
/// which rows are visible — is a pure function over data here, so `--selftest`
/// can settle the argument without a window, a daemon, or a disk. The two
/// functions that do touch the disk (`read`, and `resolvingSymlinks` inside it)
/// are `nonisolated` and are only ever called from a detached task; see
/// `FileTreeModel.load`.
enum FileTree {
    // MARK: - Where the tree roots

    /// The directory the tree should show for a focused pane.
    ///
    /// `workingDirectory` is `TerminalViewState`'s, fed by `GHOSTTY_ACTION_PWD`
    /// off OSC 7, so it follows every `cd` in a pane whose shell integration is
    /// live — which is every session this app creates since #12. It is nil
    /// until the shell first reports, and stays nil forever in a session made
    /// outside the app by a shell with no integration, so `startDir` is the
    /// fallback: zmx recorded it when the session was created and it always
    /// exists. Showing the directory a pane started in is worse than showing
    /// the one it is in, and far better than showing nothing.
    ///
    /// Both arguments are nil when no pane is focused at all, and then there is
    /// honestly no answer — the panel says so rather than guessing at a home
    /// directory nobody asked about.
    static func rootPath(workingDirectory: String?, startDir: String?) -> String? {
        normalize(workingDirectory) ?? normalize(startDir)
    }

    /// A path from somewhere else, reduced to something comparable.
    ///
    /// OSC 7 carries a `file://` URL and libghostty hands us its path
    /// component, but a shell that emits an unusual one — or a daemon that
    /// passes the URL through untouched — should not put a literal
    /// `file:///Users/...` in the header, so the scheme is stripped here and
    /// percent-escapes are undone with it.
    ///
    /// Anything not absolute afterwards is refused rather than resolved against
    /// this process's own current directory, which has nothing to do with the
    /// pane's.
    static func normalize(_ path: String?) -> String? {
        guard var text = path?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        if text.hasPrefix("file://") {
            guard let url = URL(string: text), !url.path.isEmpty else { return nil }
            text = url.path
        }
        // `standardizingPath` expands a leading tilde, collapses `..` and `//`
        // lexically, and drops a trailing slash. It also strips a leading
        // `/private` when the shorter path still exists, which is why comparing
        // two standardized paths is the only comparison worth making: OSC 7
        // reports `/private/tmp/x` where a listing of `/tmp` would produce
        // `/tmp/x`, and untreated those two never match.
        let standardized = (text as NSString).standardizingPath
        return standardized.hasPrefix("/") ? standardized : nil
    }

    // MARK: - Listing

    /// What one directory read produced. The resolved path comes back with the
    /// entries because the caller wants it for the *root* — every other entry
    /// carries its own.
    struct Listing: Sendable {
        let resolved: String
        let entries: [FileEntry]
    }

    /// Directories first, then case-insensitively by name.
    ///
    /// Dotfiles are included on purpose: this is a terminal, and a file tree
    /// beside it that cannot show `.gitignore` is lying about the directory.
    /// The tie-break on the exact name keeps `README` and `readme` in a fixed
    /// order instead of whichever the enumerator happened to produce.
    static func sorted(_ entries: [FileEntry]) -> [FileEntry] {
        entries.sorted { left, right in
            if left.isDirectory != right.isDirectory { return left.isDirectory }
            let order = left.name.localizedCaseInsensitiveCompare(right.name)
            return order == .orderedSame ? left.name < right.name : order == .orderedAscending
        }
    }

    /// Read one directory. **Blocking**, and deliberately not `@MainActor`: a
    /// tree rooted on a network mount or a directory with fifty thousand
    /// entries must not be able to stop the terminal from drawing.
    ///
    /// An unreadable or vanished directory comes back empty rather than
    /// throwing. The tree is a view of a filesystem that changes under it —
    /// half of "this directory is gone" arrives as an empty listing anyway.
    nonisolated static func read(_ path: String) -> Listing {
        let manager = FileManager.default
        let names = (try? manager.contentsOfDirectory(atPath: path)) ?? []
        let entries = names.map { name -> FileEntry in
            let child = (path as NSString).appendingPathComponent(name)
            // `isDirectory` deliberately follows symlinks: a link to a
            // directory is a directory you can open, and refusing to expand it
            // would be a worse answer than the cycle check below.
            var isDirectory: ObjCBool = false
            _ = manager.fileExists(atPath: child, isDirectory: &isDirectory)
            return FileEntry(
                path: child,
                name: name,
                isDirectory: isDirectory.boolValue,
                resolvedPath: isDirectory.boolValue ? resolvingSymlinks(child) : child
            )
        }
        return Listing(resolved: resolvingSymlinks(path), entries: sorted(entries))
    }

    private nonisolated static func resolvingSymlinks(_ path: String) -> String {
        (path as NSString).resolvingSymlinksInPath
    }

    // MARK: - What is on screen

    /// The visible rows, depth-first, given what has been loaded and what is
    /// expanded.
    ///
    /// Flattening rather than a recursive view, for two reasons. A `LazyVStack`
    /// over a flat array only builds the rows on screen, where a view that
    /// nests itself builds every level of every open folder; and this way the
    /// entire shape of the tree — ordering, depth, which folders are still
    /// loading, which ones are refused — is decidable in `--selftest` from a
    /// dictionary, with nothing on disk.
    ///
    /// The root is not a row. Its path is the header, and a root you could
    /// collapse would leave the panel showing nothing but its own title.
    static func rows(
        root: FileEntry,
        children: [String: [FileEntry]],
        expanded: Set<String>
    ) -> [FileRow] {
        var rows: [FileRow] = []

        func walk(_ parent: FileEntry, depth: Int, ancestors: [String]) {
            for entry in children[parent.path] ?? [] {
                // A directory whose resolved path is already on the way down to
                // it is a loop — `link -> ..` is the usual one — and expanding
                // it would produce an infinite tree one click at a time. The
                // row still appears; it just does not open.
                let canExpand = entry.isDirectory && !ancestors.contains(entry.resolvedPath)
                let isExpanded = canExpand && expanded.contains(entry.path)
                let loaded = children[entry.path]
                rows.append(FileRow(
                    entry: entry,
                    depth: depth,
                    isExpanded: isExpanded,
                    isLoading: isExpanded && loaded == nil,
                    canExpand: canExpand
                ))
                if isExpanded, loaded != nil {
                    walk(entry, depth: depth + 1, ancestors: ancestors + [entry.resolvedPath])
                }
            }
        }

        walk(root, depth: 0, ancestors: [root.resolvedPath])
        return rows
    }

    // MARK: - Path → text to insert

    /// The text a path becomes when it is put into a pane: what a person would
    /// have typed, ready to keep typing after.
    ///
    /// Kept separate from any gesture on purpose. Double-clicking the tree is
    /// one way to reach it and dropping files from Finder (#13) is the other,
    /// and the two have to agree about quoting and about relative-vs-absolute
    /// or the same file arrives as two different strings.
    ///
    /// The trailing space belongs to the result rather than the caller: it is
    /// what makes a second path append cleanly to a first, which is exactly
    /// what a multi-file drop needs. There is deliberately no newline — this
    /// inserts a path, it does not run anything.
    static func insertion(for path: String, relativeTo cwd: String?) -> String {
        shellQuoted(relative(path, to: cwd)) + " "
    }

    /// Relative when the file is underneath the pane's directory, absolute
    /// otherwise, because that is what someone typing it would have written.
    /// A path that *is* the directory becomes `.`, which is the only spelling
    /// of it that stays useful in a command.
    static func relative(_ path: String, to cwd: String?) -> String {
        let target = normalize(path) ?? path
        guard let base = normalize(cwd) else { return target }
        if target == base { return "." }
        let prefix = base == "/" ? "/" : base + "/"
        guard target.hasPrefix(prefix) else { return target }
        return String(target.dropFirst(prefix.count))
    }

    /// Characters a shell will not do anything with. Everything else — a space,
    /// a quote, a `$`, a `*`, a leading `~` — gets the whole string single
    /// quoted, which is the only quoting in POSIX shell that means "no, really,
    /// these characters".
    private static let unquotable = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-/@%+:,=")

    static func shellQuoted(_ text: String) -> String {
        guard !text.isEmpty else { return "''" }
        guard !text.allSatisfy(unquotable.contains) else { return text }
        // A single quote cannot appear inside single quotes, so it is closed,
        // escaped and reopened: it's → 'it'\''s'.
        return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// The file tree as state: a root, what has been listed, and what is open.
///
/// **This is not session state, and the distinction is the one rule in
/// `CLAUDE.md`.** What is expanded describes a filesystem, not a zmx session:
/// `zsm` has no opinion about it, a second window is welcome to disagree, and
/// nothing here survives — or needs to survive — the app quitting. So it lives
/// in an object, and none of it goes anywhere near a label. What *is* stored,
/// in `@AppStorage` beside the existing `railCollapsed`, is whether the sidebar
/// is open and how wide it is, which are preferences about a window rather than
/// facts about a session.
@MainActor
final class FileTreeModel: ObservableObject {
    @Published private(set) var root: FileEntry?
    @Published private(set) var children: [String: [FileEntry]] = [:]
    @Published private(set) var expanded: Set<String> = []
    @Published private(set) var loading: Set<String> = []
    @Published var selected: String?

    /// Bumped on every re-root. A listing of a huge directory can still be in
    /// flight when the focused pane changes, and without this it would land in
    /// the new tree as a folder from the old one.
    private var generation = 0

    var rows: [FileRow] {
        guard let root else { return [] }
        return FileTree.rows(root: root, children: children, expanded: expanded)
    }

    var isLoadingRoot: Bool { root.map { loading.contains($0.path) } ?? false }

    /// Point the tree somewhere else, or nowhere.
    ///
    /// Re-rooting resets what is expanded, and that is accepted rather than
    /// worked around: the paths in the old tree mean nothing under a new root,
    /// and keeping a pinned root is a separate feature nobody has asked for
    /// yet. Re-rooting at the directory it is already showing does nothing at
    /// all, which is what keeps a `cd` in an unfocused pane, or clicking
    /// between two panes in the same project, from folding the tree up.
    func setRoot(_ path: String?) {
        let normalized = FileTree.normalize(path)
        guard normalized != root?.path else { return }
        generation += 1
        children = [:]
        expanded = []
        loading = []
        selected = nil
        guard let normalized else {
            root = nil
            return
        }
        // The resolved path is a `realpath` call, so it cannot be made here;
        // the listing brings it back and `apply` corrects the root. Until then
        // the literal path stands in, which is right for every root that is not
        // itself a symlink and harmless for the ones that are.
        root = FileEntry(path: normalized, name: (normalized as NSString).lastPathComponent, isDirectory: true)
        Log.debug("file tree root: \(normalized)")
        load(normalized)
    }

    func toggle(_ row: FileRow) {
        guard row.canExpand else { return }
        let path = row.entry.path
        if expanded.contains(path) {
            // The listing is kept. Collapsing is not a statement that the
            // contents are wrong, and re-opening a folder should not cost
            // another directory read.
            expanded.remove(path)
        } else {
            expanded.insert(path)
            if children[path] == nil { load(path) }
        }
    }

    /// Everything the tree knows, asked again. There is no filesystem watcher
    /// in this version — that is where the complexity of the feature actually
    /// lives — so a file created in the pane appears when this is pressed.
    func refresh() {
        guard let root else { return }
        children = [:]
        load(root.path)
        for path in expanded { load(path) }
    }

    private func load(_ path: String) {
        guard !loading.contains(path) else { return }
        loading.insert(path)
        let generation = generation
        // `Task.detached`, not `Task`. A `Task` created here would inherit this
        // object's main-actor isolation and read the directory on the main
        // thread, which is the one thing this feature must never do.
        Task.detached(priority: .utility) {
            let listing = FileTree.read(path)
            await MainActor.run { self.apply(listing, for: path, generation: generation) }
        }
    }

    private func apply(_ listing: FileTree.Listing, for path: String, generation: Int) {
        guard generation == self.generation else { return }
        loading.remove(path)
        children[path] = listing.entries
        if let root, root.path == path {
            self.root = FileEntry(
                path: root.path, name: root.name, isDirectory: true, resolvedPath: listing.resolved
            )
        }
    }
}

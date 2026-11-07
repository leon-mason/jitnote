import CGit2
import Foundation

/// One notebook = one ordinary Git working copy. Everything the app does to a notebook goes
/// through here, and everything ends up as plain Git objects, so any other Git client (or an
/// AI tool) can work on the same repository.
///
/// The same rules as the Android app (`NotebookGit.kt`), which the tests check case by case:
/// - commit local changes → fetch → merge (never rebase) → push; never force-push.
/// - a file changed on both sides (or deleted on one and changed on the other) is never decided by
///   the app: `sync` stops, before touching anything, and reports the file as a `PendingConflict`;
///   the caller asks the user and syncs again with `choices`. The side that loses stays in history.
/// - another program's `index.lock` or unfinished merge is never cleaned up (see `prepareForSync`).
///
/// Not thread-safe: callers serialize access per notebook (see `Notebooks.run`), which is why it is
/// marked Sendable without checks.
final class NotebookGit: @unchecked Sendable {
    static let remoteName = "origin"
    static let defaultBranch = "main"
    private static let maxAttempts = 3

    let workTree: URL

    init(workTree: URL) {
        Git2.initialize()
        self.workTree = workTree
    }

    /// The address of the cloud repository this folder was downloaded from; nil when the folder is not a
    /// notebook working copy at all (the error then comes from opening it).
    func originUrl() throws -> String? {
        try withRepo { repo in
            var remote: OpaquePointer?
            guard git_remote_lookup(&remote, repo, Self.remoteName) == 0 else { return nil }
            defer { git_remote_free(remote) }
            return git_remote_url(remote).map { String(cString: $0) }
        }
    }

    func hasLocalChanges() throws -> Bool {
        try withRepo { try !isClean($0) }
    }

    /// True when something on this Mac has not reached the cloud yet.
    func hasUnsyncedWork() throws -> Bool {
        try withRepo { repo in
            if try !isClean(repo) { return true }
            guard let head = headId(repo) else { return false }
            guard let remote = refId(repo, Self.remoteRef(try branchName(repo))) else { return true }
            return !isAncestor(repo, head, of: remote)
        }
    }

    /// Commits every change in the working tree. Returns false when there was nothing to commit.
    @discardableResult
    func commitAll(author: Author, device: String, message: String? = nil) throws -> Bool {
        try withRepo { repo in
            try applyIdentity(repo, author)
            return try commitAllInternal(repo, author: author, device: device, message: message)
        }
    }

    /// [choices] settles conflicts a previous call reported in `SyncResult.pending`: which side wins, by path.
    func sync(credentials: Credentials?, author: Author, device: String, choices: [String: Side] = [:]) throws -> SyncResult {
        do {
            return try withRepo { try syncInternal($0, credentials: credentials, author: author, device: device, choices: choices) }
        } catch {
            throw Self.classify(error)
        }
    }

    /// Versions of [path], newest first.
    func history(_ path: String, max: Int = 200) throws -> [Version] {
        try withRepo { repo in
            guard let head = headId(repo) else { return [] }
            return try commits(repo, from: head, hiding: nil, touching: path, max: max).map {
                Version(commit: Git2.string($0.id), time: $0.time, message: $0.summary, author: $0.author)
            }
        }
    }

    /// Content of [path] at [commit], or nil if the file does not exist there.
    func read(at commit: String, path: String) throws -> Data? {
        try withRepo { repo in try blobId(at: Git2.oid(commit), path: path, in: repo).map { try blobData($0, in: repo) } }
    }

    /// Overwrites [path] with its content at [commit]. What is there now is recorded first (just this
    /// file), so restoring never loses the current text; the restored text goes in with the next sync.
    func restore(_ path: String, commit: String, author: Author, device: String) throws {
        try withRepo { repo in
            let content = try blobId(at: Git2.oid(commit), path: path, in: repo).map { try blobData($0, in: repo) }
            try applyIdentity(repo, author)
            _ = try commitPathsInternal(repo, [path], author: author, device: device, message: nil)
            try writeOrDelete(path, content)
        }
    }

    // MARK: - Sync internals

    private func syncInternal(_ repo: OpaquePointer, credentials: Credentials?, author: Author, device: String, choices: [String: Side]) throws -> SyncResult {
        try prepareForSync(repo)
        defer { releaseSyncMarker(repo) }
        try applyIdentity(repo, author)
        // Records of earlier versions, which kept the newer side and let people switch afterwards. Unused now.
        try? FileManager.default.removeItem(at: legacyConflictFile)
        _ = try commitAllInternal(repo, author: author, device: device, message: nil)
        let branch = try branchName(repo)
        var pulled = false
        var resolved = 0
        for _ in 0..<Self.maxAttempts {
            try fetch(repo, credentials: credentials)
            let remote = refId(repo, Self.remoteRef(branch))
            if let remote {
                let merge = try mergeRemote(repo, theirs: remote, branch: branch, author: author, device: device, choices: choices)
                // Stop before touching anything: the working tree is left as it was while the user decides.
                if !merge.pending.isEmpty { return SyncResult(pulled: pulled, pushed: false, resolved: resolved, pending: merge.pending) }
                pulled = pulled || merge.changed
                resolved += merge.resolved
            }
            guard let local = headId(repo), local != remote else {
                return SyncResult(pulled: pulled, pushed: false, resolved: resolved, pending: [])
            }
            if try push(repo, branch: branch, credentials: credentials) {
                try ensureUpstream(repo, branch: branch)
                return SyncResult(pulled: pulled, pushed: true, resolved: resolved, pending: [])
            }
            // Someone pushed between our fetch and push: fetch and merge again.
        }
        throw SyncError(.rejected, "云端在同步期间不断变化，请稍后再试")
    }

    private func fetch(_ repo: OpaquePointer, credentials: Credentials?) throws {
        let remote = try lookupRemote(repo)
        defer { git_remote_free(remote) }
        let context = TransferContext(credentials: credentials)
        var options = git_fetch_options()
        try Git2.check(git_fetch_options_init(&options, UInt32(GIT_FETCH_OPTIONS_VERSION)))
        options.prune = GIT_FETCH_PRUNE
        context.install(&options.callbacks)
        try withExtendedLifetime(context) {
            _ = try Git2.check(git_remote_fetch(remote, nil, &options, nil))
        }
    }

    private struct MergeOutcome {
        let changed: Bool
        /// Files that were both changed and settled with the user's choices.
        let resolved: Int
        /// Conflicts waiting for a choice; nothing was merged when there are any.
        let pending: [PendingConflict]
    }

    private func mergeRemote(
        _ repo: OpaquePointer,
        theirs: git_oid,
        branch: String,
        author: Author,
        device: String,
        choices: [String: Side]
    ) throws -> MergeOutcome {
        guard let head = headId(repo) else {
            // Nothing committed on this Mac yet: adopt the cloud's history as is.
            var ref: OpaquePointer?
            var target = theirs
            try Git2.check(git_reference_create(&ref, repo, "refs/heads/\(branch)", &target, 1, "sync: adopt cloud"))
            git_reference_free(ref)
            try checkoutHead(repo, force: true)
            return MergeOutcome(changed: true, resolved: 0, pending: [])
        }
        if isAncestor(repo, theirs, of: head) { return MergeOutcome(changed: false, resolved: 0, pending: []) }

        if isAncestor(repo, head, of: theirs) {
            try fastForward(repo, to: theirs, branch: branch)
            return MergeOutcome(changed: true, resolved: 0, pending: [])
        }

        // Find out first, in memory, whether both sides touched the same thing. Merging for real would
        // write conflict markers into the notebook folder, where another program could read them.
        let conflicts = try findConflicts(repo, ours: head, theirs: theirs)
        if conflicts.contains(where: { choices[$0.path] == nil }) {
            return MergeOutcome(changed: false, resolved: 0, pending: conflicts)
        }

        var annotated: OpaquePointer?
        var theirsCopy = theirs
        try Git2.check(git_annotated_commit_lookup(&annotated, repo, &theirsCopy))
        defer { git_annotated_commit_free(annotated) }
        var mergeOptions = git_merge_options()
        try Git2.check(git_merge_options_init(&mergeOptions, UInt32(GIT_MERGE_OPTIONS_VERSION)))
        var checkout = git_checkout_options()
        try Git2.check(git_checkout_options_init(&checkout, UInt32(GIT_CHECKOUT_OPTIONS_VERSION)))
        checkout.checkout_strategy = GIT_CHECKOUT_SAFE.rawValue | GIT_CHECKOUT_ALLOW_CONFLICTS.rawValue
        var heads: [OpaquePointer?] = [annotated]
        guard git_merge(repo, &heads, 1, &mergeOptions, &checkout) == 0 else {
            // Typically a file was written while syncing; libgit2 left the working tree untouched.
            throw SyncError(.other, "有文件正在被修改，请稍后再同步")
        }
        defer { git_repository_state_cleanup(repo) }

        let index = try repoIndex(repo)
        defer { git_index_free(index) }
        if git_index_has_conflicts(index) == 1 {
            let count = try resolveConflicts(repo, index: index, ours: head, theirs: theirs, author: author, device: device, choices: choices)
            return MergeOutcome(changed: true, resolved: count, pending: [])
        }
        try commitIndex(repo, index: index, parents: [head, theirs], author: author,
                        message: Self.commitMessage("同步：合并云端修改", device: device))
        return MergeOutcome(changed: true, resolved: 0, pending: [])
    }

    /// The files [ours] and [theirs] cannot be merged on their own, with what each side has.
    /// Nothing in the repository or the working tree changes.
    private func findConflicts(_ repo: OpaquePointer, ours: git_oid, theirs: git_oid) throws -> [PendingConflict] {
        var ourCommit: OpaquePointer?, theirCommit: OpaquePointer?
        var ourId = ours, theirId = theirs
        try Git2.check(git_commit_lookup(&ourCommit, repo, &ourId))
        defer { git_commit_free(ourCommit) }
        try Git2.check(git_commit_lookup(&theirCommit, repo, &theirId))
        defer { git_commit_free(theirCommit) }
        var options = git_merge_options()
        try Git2.check(git_merge_options_init(&options, UInt32(GIT_MERGE_OPTIONS_VERSION)))
        var merged: OpaquePointer?
        try Git2.check(git_merge_commits(&merged, repo, ourCommit, theirCommit, &options))
        defer { git_index_free(merged) }
        guard git_index_has_conflicts(merged) == 1 else { return [] }

        var found: [PendingConflict] = []
        for stage in try conflictStages(merged!) {
            found.append(PendingConflict(
                path: stage.path,
                local: try stage.ours.map { try blobData($0, in: repo) },
                cloud: try stage.theirs.map { try blobData($0, in: repo) }
            ))
        }
        return found
    }

    /// "ours" = this Mac, "theirs" = cloud. A missing side means that side deleted the file.
    private func conflictStages(_ index: OpaquePointer) throws -> [(path: String, ours: git_oid?, theirs: git_oid?)] {
        var stages: [(path: String, ours: git_oid?, theirs: git_oid?)] = []
        var iterator: OpaquePointer?
        try Git2.check(git_index_conflict_iterator_new(&iterator, index))
        defer { git_index_conflict_iterator_free(iterator) }
        var ancestor: UnsafePointer<git_index_entry>?
        var our: UnsafePointer<git_index_entry>?
        var their: UnsafePointer<git_index_entry>?
        while git_index_conflict_next(&ancestor, &our, &their, iterator) == 0 {
            guard let entry = our ?? their ?? ancestor else { continue }
            if our == nil && their == nil { continue }
            stages.append((String(cString: entry.pointee.path), our?.pointee.id, their?.pointee.id))
        }
        return stages
    }

    /// Settles every conflicted file in the half-finished merge with the side the user chose, then
    /// commits it. Both sides are parents of that commit, so the side that lost is still in history.
    private func resolveConflicts(
        _ repo: OpaquePointer,
        index: OpaquePointer,
        ours: git_oid,
        theirs: git_oid,
        author: Author,
        device: String,
        choices: [String: Side]
    ) throws -> Int {
        let stages = try conflictStages(index)
        for stage in stages {
            guard let side = choices[stage.path] else {
                // findConflicts saw this merge first, so this means the two disagree. Do not guess.
                throw SyncError(.other, "合并时发现新的冲突，请重新同步")
            }
            let chosen = side == .local ? stage.ours : stage.theirs
            if let chosen {
                try writeOrDelete(stage.path, blobData(chosen, in: repo))
                try Git2.check(git_index_add_bypath(index, stage.path))
            } else {
                // The chosen side deleted the file.
                try writeOrDelete(stage.path, nil)
                try Git2.check(git_index_remove_bypath(index, stage.path))
            }
        }
        try Git2.check(git_index_write(index))
        try commitIndex(repo, index: index, parents: [ours, theirs], author: author,
                        message: Self.commitMessage("同步：合并云端修改（\(stages.count) 个文件两边都改了，按你的选择处理）", device: device))
        return stages.count
    }

    private func push(_ repo: OpaquePointer, branch: String, credentials: Credentials?) throws -> Bool {
        let remote = try lookupRemote(repo)
        defer { git_remote_free(remote) }
        let context = TransferContext(credentials: credentials)
        var options = git_push_options()
        try Git2.check(git_push_options_init(&options, UInt32(GIT_PUSH_OPTIONS_VERSION)))
        context.install(&options.callbacks)
        let ref = "refs/heads/\(branch)"
        let code = withExtendedLifetime(context) {
            Git2.withStrArray(["\(ref):\(ref)"]) { git_remote_push(remote, &$0, &options) }
        }
        if code == GIT_ENONFASTFORWARD.rawValue { return false }
        try Git2.check(code)
        guard let rejection = context.pushRejections.first else { return true }
        let lower = rejection.lowercased()
        if lower.contains("non-fast-forward") || lower.contains("fetch first") || lower.contains("stale") { return false }
        throw SyncError(.rejected, "云端拒绝了上传：\(rejection)")
    }

    /// How long a sync waits for another program's `index.lock` to go away. Programs working on the
    /// notebook (an AI, a terminal) hold it for well under a second per command; the wait is a
    /// variable only so tests do not have to sit it out.
    static var indexLockWait: TimeInterval = 3

    /// Written to `.git/jitnote/` while a sync runs. A leftover one means a sync of this app died, which is
    /// the only case where a half-finished merge or an `index.lock` is ours to clean up.
    static let syncMarkerPath = "jitnote/syncing"

    private var syncMarker: URL { gitDir.appendingPathComponent(Self.syncMarkerPath) }

    /// Starts a sync from a state it may build on. Another program's lock or unfinished merge is left
    /// alone (design.md, product principle 5): removing them could throw away its work.
    private func prepareForSync(_ repo: OpaquePointer) throws {
        if FileManager.default.fileExists(atPath: syncMarker.path) {
            try recover(repo)
        } else {
            let lock = gitDir.appendingPathComponent("index.lock")
            let deadline = Date().addingTimeInterval(Self.indexLockWait)
            while FileManager.default.fileExists(atPath: lock.path) {
                if Date() >= deadline { throw SyncError(.other, "有其他程序正在处理这个笔记本，请稍后再同步") }
                Thread.sleep(forTimeInterval: 0.1)
            }
            guard git_repository_state(repo) == Int32(GIT_REPOSITORY_STATE_NONE.rawValue) else {
                throw SyncError(.other, "有其他程序正在合并这个笔记本，请等它完成后再同步")
            }
        }
        try FileManager.default.createDirectory(at: syncMarker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: syncMarker)
    }

    /// Keeps the marker when a failed sync left a merge behind, so the next sync still recognizes it as ours.
    private func releaseSyncMarker(_ repo: OpaquePointer) {
        guard git_repository_state(repo) == Int32(GIT_REPOSITORY_STATE_NONE.rawValue) else { return }
        try? FileManager.default.removeItem(at: syncMarker)
    }

    /// Leaves the repository in a clean state after a crash in the middle of a previous sync of this app.
    private func recover(_ repo: OpaquePointer) throws {
        try? FileManager.default.removeItem(at: gitDir.appendingPathComponent("index.lock"))
        guard git_repository_state(repo) != Int32(GIT_REPOSITORY_STATE_NONE.rawValue) else { return }
        // Abort the unfinished merge. Local work was committed before merging, so nothing is lost.
        if let head = headId(repo) {
            var commit: OpaquePointer?
            var id = head
            try Git2.check(git_commit_lookup(&commit, repo, &id))
            defer { git_commit_free(commit) }
            try Git2.check(git_reset(repo, commit, GIT_RESET_HARD, nil))
        }
        git_repository_state_cleanup(repo)
    }

    private func commitAllInternal(_ repo: OpaquePointer, author: Author, device: String, message: String?) throws -> Bool {
        if try isClean(repo) { return false }
        let index = try repoIndex(repo)
        defer { git_index_free(index) }
        try Git2.withStrArray([]) { paths in
            try Git2.check(git_index_add_all(index, &paths, GIT_INDEX_ADD_DEFAULT.rawValue, nil, nil))
            try Git2.check(git_index_update_all(index, &paths, nil, nil))
        }
        try Git2.check(git_index_write(index))

        let headTree = try headId(repo).map { try tree(of: $0, in: repo) }
        defer { headTree.map { git_tree_free($0) } }
        let (added, changed, removed) = try changes(repo, from: headTree, to: index, only: nil)
        guard let summary = message ?? Self.describeChanges(added: added, changed: changed, removed: removed) else { return false }
        let parents = headId(repo).map { [$0] } ?? []
        try commitIndex(repo, index: index, parents: parents, author: author, message: Self.commitMessage(summary, device: device))
        return true
    }

    /// Commits only [paths] (files, or folders with everything under them); every other change stays
    /// uncommitted, and so does whatever another tool has staged. Returns false when those paths have
    /// nothing new. Used to keep a version of something before the app deletes or overwrites it.
    @discardableResult
    func commitPaths(_ paths: [String], author: Author, device: String, message: String? = nil) throws -> Bool {
        try withRepo { repo in
            try applyIdentity(repo, author)
            return try commitPathsInternal(repo, paths, author: author, device: device, message: message)
        }
    }

    private func commitPathsInternal(_ repo: OpaquePointer, _ paths: [String], author: Author, device: String, message: String?) throws -> Bool {
        let index = try repoIndex(repo)
        defer { git_index_free(index) }
        for path in paths { try stage(path, in: index, repo: repo) }
        try Git2.check(git_index_write(index))

        let headTree = try headId(repo).map { try tree(of: $0, in: repo) }
        defer { headTree.map { git_tree_free($0) } }
        let (added, changed, removed) = try changes(repo, from: headTree, to: index, only: paths)
        guard let summary = message ?? Self.describeChanges(added: added, changed: changed, removed: removed) else { return false }

        // The commit is HEAD's tree plus just these paths. Building it from the real index would also
        // commit whatever else is staged there.
        var pending: OpaquePointer?
        try Git2.check(git_index_new(&pending))
        defer { git_index_free(pending) }
        if let headTree { try Git2.check(git_index_read_tree(pending, headTree)) }
        for path in removed { try Git2.check(git_index_remove(pending, path, 0)) }
        for path in added + changed {
            guard let entry = git_index_get_bypath(index, path, 0) else { continue }
            try Git2.check(git_index_add(pending, entry))
        }
        let parents = headId(repo).map { [$0] } ?? []
        try commitIndex(repo, index: pending!, parents: parents, author: author, message: Self.commitMessage(summary, device: device))
        return true
    }

    /// Records the working-tree state of [path] (a file, or a folder and what is in it) in [index].
    /// Paths are matched literally: a note called "a[1].md" must not be read as a glob.
    private func stage(_ path: String, in index: OpaquePointer, repo: OpaquePointer) throws {
        let url = workTree.appendingPathComponent(path)
        var isFolder: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder)
        var onDisk: Set<String> = []
        if exists && isFolder.boolValue {
            // Relative paths come straight from the enumerator: its URLs have symlinks resolved
            // (/var → /private/var), so they cannot be cut down to a path inside the notebook.
            if let walker = FileManager.default.enumerator(atPath: url.path) {
                for case let inside as String in walker {
                    if walker.fileAttributes?[.type] as? FileAttributeType == .typeDirectory { continue }
                    onDisk.insert(path + "/" + inside)
                }
            }
        } else if exists {
            onDisk.insert(path)
        }
        for file in onDisk {
            // New files obey .gitignore; a file that is already tracked is recorded either way.
            var ignored: Int32 = 0
            if git_index_get_bypath(index, file, 0) == nil {
                try Git2.check(git_ignore_path_is_ignored(&ignored, repo, file))
                if ignored == 1 { continue }
            }
            try Git2.check(git_index_add_bypath(index, file))
        }
        // Whatever the index tracks under [path] but is no longer on disk was deleted.
        for i in 0..<git_index_entrycount(index) {
            guard let entry = git_index_get_byindex(index, i) else { continue }
            let tracked = String(cString: entry.pointee.path)
            guard tracked == path || tracked.hasPrefix(path + "/"), !onDisk.contains(tracked) else { continue }
            _ = git_index_remove(index, tracked, 0)
        }
    }

    /// Paths that differ between [headTree] and [index], optionally only those at or under [only].
    private func changes(_ repo: OpaquePointer, from headTree: OpaquePointer?, to index: OpaquePointer, only: [String]?)
        throws -> (added: [String], changed: [String], removed: [String]) {
        var added: [String] = [], changed: [String] = [], removed: [String] = []
        var diff: OpaquePointer?
        try Git2.check(git_diff_tree_to_index(&diff, repo, headTree, index, nil))
        defer { git_diff_free(diff) }
        for i in 0..<git_diff_num_deltas(diff) {
            let delta = git_diff_get_delta(diff, i)!.pointee
            let path = String(cString: delta.status == GIT_DELTA_DELETED ? delta.old_file.path : delta.new_file.path)
            if let only, !only.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { continue }
            switch delta.status {
            case GIT_DELTA_ADDED: added.append(path)
            case GIT_DELTA_DELETED: removed.append(path)
            default: changed.append(path)
            }
        }
        return (added, changed, removed)
    }

    // MARK: - libgit2 helpers

    private var gitDir: URL { workTree.appendingPathComponent(".git") }

    private var legacyConflictFile: URL { gitDir.appendingPathComponent("jitnote/conflicts.json") }

    private func withRepo<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        var repo: OpaquePointer?
        try Git2.check(git_repository_open(&repo, workTree.path))
        defer { git_repository_free(repo) }
        return try body(repo!)
    }

    private func isClean(_ repo: OpaquePointer) throws -> Bool {
        var options = git_status_options()
        try Git2.check(git_status_options_init(&options, UInt32(GIT_STATUS_OPTIONS_VERSION)))
        options.show = GIT_STATUS_SHOW_INDEX_AND_WORKDIR
        options.flags = GIT_STATUS_OPT_INCLUDE_UNTRACKED.rawValue | GIT_STATUS_OPT_RECURSE_UNTRACKED_DIRS.rawValue
            | GIT_STATUS_OPT_EXCLUDE_SUBMODULES.rawValue
        var list: OpaquePointer?
        try Git2.check(git_status_list_new(&list, repo, &options))
        defer { git_status_list_free(list) }
        return git_status_list_entrycount(list) == 0
    }

    private func repoIndex(_ repo: OpaquePointer) throws -> OpaquePointer {
        var index: OpaquePointer?
        try Git2.check(git_repository_index(&index, repo))
        return index!
    }

    private func headId(_ repo: OpaquePointer) -> git_oid? { refId(repo, "HEAD") }

    private func refId(_ repo: OpaquePointer, _ name: String) -> git_oid? {
        var oid = git_oid()
        return git_reference_name_to_id(&oid, repo, name) == 0 ? oid : nil
    }

    /// The branch HEAD points at, even before its first commit.
    private func branchName(_ repo: OpaquePointer) throws -> String {
        var head: OpaquePointer?
        try Git2.check(git_reference_lookup(&head, repo, "HEAD"))
        defer { git_reference_free(head) }
        guard let target = git_reference_symbolic_target(head) else { throw SyncError(.other, "笔记本没有处在任何分支上") }
        return String(cString: target).replacingOccurrences(of: "refs/heads/", with: "")
    }

    private func lookupRemote(_ repo: OpaquePointer) throws -> OpaquePointer {
        var remote: OpaquePointer?
        try Git2.check(git_remote_lookup(&remote, repo, Self.remoteName))
        return remote!
    }

    private func isAncestor(_ repo: OpaquePointer, _ ancestor: git_oid, of descendant: git_oid) -> Bool {
        if ancestor == descendant { return true }
        var a = ancestor, d = descendant
        return git_graph_descendant_of(repo, &d, &a) == 1
    }

    private func tree(of commitId: git_oid, in repo: OpaquePointer) throws -> OpaquePointer {
        var commit: OpaquePointer?
        var id = commitId
        try Git2.check(git_commit_lookup(&commit, repo, &id))
        defer { git_commit_free(commit) }
        var tree: OpaquePointer?
        try Git2.check(git_commit_tree(&tree, commit))
        return tree!
    }

    private func blobId(at commitId: git_oid, path: String, in repo: OpaquePointer) throws -> git_oid? {
        let tree = try tree(of: commitId, in: repo)
        defer { git_tree_free(tree) }
        var entry: OpaquePointer?
        guard git_tree_entry_bypath(&entry, tree, path) == 0 else { return nil }
        defer { git_tree_entry_free(entry) }
        guard git_tree_entry_type(entry) == GIT_OBJECT_BLOB else { return nil }
        return git_tree_entry_id(entry)!.pointee
    }

    private func blobData(_ id: git_oid, in repo: OpaquePointer) throws -> Data {
        var blob: OpaquePointer?
        var oid = id
        try Git2.check(git_blob_lookup(&blob, repo, &oid))
        defer { git_blob_free(blob) }
        return Data(bytes: git_blob_rawcontent(blob), count: Int(git_blob_rawsize(blob)))
    }

    private struct CommitInfo {
        let id: git_oid
        /// Author time in ms.
        let time: Int64
        let summary: String
        let author: String
    }

    /// Commits on [from] (not reachable from [hiding]) whose [path] differs from every parent, newest first.
    /// Like `git log -- path` without history simplification, so the side of a merge that lost a conflict
    /// still shows up. Android's `history` walks the same way.
    private func commits(_ repo: OpaquePointer, from: git_oid, hiding: git_oid?, touching path: String, max: Int) throws -> [CommitInfo] {
        var walk: OpaquePointer?
        try Git2.check(git_revwalk_new(&walk, repo))
        defer { git_revwalk_free(walk) }
        try Git2.check(git_revwalk_sorting(walk, GIT_SORT_TOPOLOGICAL.rawValue | GIT_SORT_TIME.rawValue))
        var start = from
        try Git2.check(git_revwalk_push(walk, &start))
        if var hide = hiding { try Git2.check(git_revwalk_hide(walk, &hide)) }

        var result: [CommitInfo] = []
        var id = git_oid()
        while result.count < max, git_revwalk_next(&id, walk) == 0 {
            var commit: OpaquePointer?
            try Git2.check(git_commit_lookup(&commit, repo, &id))
            defer { git_commit_free(commit) }
            guard try touches(commit!, path: path, in: repo) else { continue }
            let author = git_commit_author(commit)!.pointee
            result.append(CommitInfo(
                id: id,
                time: Int64(author.when.time) * 1000,
                summary: String(cString: git_commit_summary(commit)),
                author: String(cString: author.name)
            ))
        }
        return result
    }

    private func touches(_ commit: OpaquePointer, path: String, in repo: OpaquePointer) throws -> Bool {
        let id = git_commit_id(commit)!.pointee
        let mine = try blobId(at: id, path: path, in: repo)
        let parents = git_commit_parentcount(commit)
        if parents == 0 { return mine != nil }
        for i in 0..<parents {
            let parent = git_commit_parent_id(commit, i)!.pointee
            if try blobId(at: parent, path: path, in: repo) == mine { return false }
        }
        return true
    }

    private func commitIndex(_ repo: OpaquePointer, index: OpaquePointer, parents: [git_oid], author: Author, message: String) throws {
        var treeId = git_oid()
        // _to: an index built in memory is not attached to the repository.
        try Git2.check(git_index_write_tree_to(&treeId, index, repo))
        var tree: OpaquePointer?
        try Git2.check(git_tree_lookup(&tree, repo, &treeId))
        defer { git_tree_free(tree) }

        var parentCommits: [OpaquePointer?] = []
        defer { parentCommits.forEach { git_commit_free($0) } }
        for parent in parents {
            var commit: OpaquePointer?
            var id = parent
            try Git2.check(git_commit_lookup(&commit, repo, &id))
            parentCommits.append(commit)
        }

        var signature: UnsafeMutablePointer<git_signature>?
        try Git2.check(git_signature_now(&signature, author.name, author.email))
        defer { git_signature_free(signature) }
        var out = git_oid()
        try parentCommits.withUnsafeMutableBufferPointer { buffer in
            _ = try Git2.check(git_commit_create(&out, repo, "HEAD", signature, signature, nil, message, tree, buffer.count, buffer.baseAddress))
        }
    }

    private func fastForward(_ repo: OpaquePointer, to target: git_oid, branch: String) throws {
        var commit: OpaquePointer?
        var id = target
        try Git2.check(git_commit_lookup(&commit, repo, &id))
        defer { git_commit_free(commit) }
        var checkout = git_checkout_options()
        try Git2.check(git_checkout_options_init(&checkout, UInt32(GIT_CHECKOUT_OPTIONS_VERSION)))
        checkout.checkout_strategy = GIT_CHECKOUT_SAFE.rawValue
        guard git_checkout_tree(repo, commit, &checkout) == 0 else {
            throw SyncError(.other, "有文件正在被修改，请稍后再同步")
        }
        var ref: OpaquePointer?
        try Git2.check(git_reference_create(&ref, repo, "refs/heads/\(branch)", &id, 1, "sync: fast-forward"))
        git_reference_free(ref)
    }

    private func checkoutHead(_ repo: OpaquePointer, force: Bool) throws {
        var checkout = git_checkout_options()
        try Git2.check(git_checkout_options_init(&checkout, UInt32(GIT_CHECKOUT_OPTIONS_VERSION)))
        checkout.checkout_strategy = force ? GIT_CHECKOUT_FORCE.rawValue : GIT_CHECKOUT_SAFE.rawValue
        try Git2.check(git_checkout_head(repo, &checkout))
    }

    /// Gives other tools working in this notebook a name to commit with, but never replaces one the
    /// user (or an earlier setup) already chose. This app's own commits name their author explicitly.
    private func applyIdentity(_ repo: OpaquePointer, _ author: Author) throws {
        try withConfig(repo) { config in
            if Self.configString(config, "user.name") == nil {
                try Git2.check(git_config_set_string(config, "user.name", author.name))
            }
            if Self.configString(config, "user.email") == nil {
                try Git2.check(git_config_set_string(config, "user.email", author.email))
            }
        }
    }

    private func ensureUpstream(_ repo: OpaquePointer, branch: String) throws {
        try withConfig(repo) { config in
            if Self.configString(config, "branch.\(branch).remote") != nil { return }
            try Git2.check(git_config_set_string(config, "branch.\(branch).remote", Self.remoteName))
            try Git2.check(git_config_set_string(config, "branch.\(branch).merge", "refs/heads/\(branch)"))
        }
    }

    private func withConfig(_ repo: OpaquePointer, _ body: (OpaquePointer) throws -> Void) throws {
        var config: OpaquePointer?
        try Git2.check(git_repository_config(&config, repo))
        defer { git_config_free(config) }
        try body(config!)
    }

    private static func configString(_ config: OpaquePointer, _ name: String) -> String? {
        var buffer = git_buf()
        defer { git_buf_dispose(&buffer) }
        guard git_config_get_string_buf(&buffer, config, name) == 0, let pointer = buffer.ptr else { return nil }
        return String(cString: pointer)
    }

    private func writeOrDelete(_ path: String, _ content: Data?) throws {
        let file = workTree.appendingPathComponent(path)
        if let content {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: file)
        } else {
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: - Statics

    /// Downloads [url] into [dir]. Works for empty repositories too.
    @discardableResult
    static func clone(url: String, into dir: URL, credentials: Credentials?, onProgress: ((Int, Int) -> Void)? = nil) throws -> NotebookGit {
        Git2.initialize()
        let context = TransferContext(credentials: credentials, onProgress: onProgress)
        var options = git_clone_options()
        // A folder the user chose (an empty one) must survive a failed download; only what was put in it goes.
        let existed = FileManager.default.fileExists(atPath: dir.path)
        do {
            try Git2.check(git_clone_options_init(&options, UInt32(GIT_CLONE_OPTIONS_VERSION)))
            context.install(&options.fetch_opts.callbacks)
            var repo: OpaquePointer?
            try withExtendedLifetime(context) {
                _ = try Git2.check(git_clone(&repo, url, dir.path, &options))
            }
            defer { git_repository_free(repo) }
            try prepare(repo!)
        } catch {
            if existed {
                for item in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
                    try? FileManager.default.removeItem(at: item)
                }
            } else {
                try? FileManager.default.removeItem(at: dir)
            }
            throw classify(error)
        }
        return NotebookGit(workTree: dir)
    }

    private static func prepare(_ repo: OpaquePointer) throws {
        var config: OpaquePointer?
        try Git2.check(git_repository_config(&config, repo))
        defer { git_config_free(config) }
        // Store file names composed (NFC), as Git on other systems expects.
        try Git2.check(git_config_set_bool(config, "core.precomposeunicode", 1))
        var head = git_oid()
        if git_reference_name_to_id(&head, repo, "HEAD") != 0 {
            var refs = git_strarray()
            defer { git_strarray_dispose(&refs) }
            try Git2.check(git_reference_list(&refs, repo))
            if refs.count == 0 {
                // Empty cloud repository: start on "main" like GitHub / Gitee do.
                try Git2.check(git_repository_set_head(repo, "refs/heads/\(defaultBranch)"))
            }
        }
    }

    private static func remoteRef(_ branch: String) -> String { "refs/remotes/\(remoteName)/\(branch)" }

    static func commitMessage(_ summary: String, device: String) -> String { "\(summary)\n\n来自 记特 · \(device)" }

    /// Human-readable commit summary such as "编辑：读书笔记".
    static func describeChanges(added: [String], changed: [String], removed: [String]) -> String? {
        let total = added.count + changed.count + removed.count
        if total == 0 { return nil }
        if changed.isEmpty, let move = describeMove(added: added, removed: removed) { return move }
        if total == 1 {
            if let path = added.first { return "新建：\(title(path))" }
            if let path = changed.first { return "编辑：\(title(path))" }
            return "删除：\(title(removed[0]))"
        }
        var names: [String] = []
        for name in (changed + added + removed).map(title) where !names.contains(name) { names.append(name) }
        let more = names.count > 3 ? " 等" : ""
        return "更新 \(total) 个文件：\(names.prefix(3).joined(separator: "、"))\(more)"
    }

    /// "移动：…" or "重命名：…" when the only change is files that disappeared and reappeared elsewhere
    /// (design.md「同步规则」). Without this a file moved to another folder would read as
    /// "重命名：读书笔记 → 读书笔记". A folder that moved as a whole is recognised by its files keeping
    /// their paths relative to it; anything else falls back to the generic summary.
    private static func describeMove(added: [String], removed: [String]) -> String? {
        if added.count == 1 && removed.count == 1 {
            let from = removed[0], to = added[0]
            let fromDir = directory(of: from), toDir = directory(of: to)
            if fromDir == toDir { return "重命名：\(title(from)) → \(title(to))" }
            if from.split(separator: "/").last == to.split(separator: "/").last {
                return "移动：\(title(from)) → \(folderLabel(toDir))"
            }
            return "重命名：\(title(from)) → \(toDir.isEmpty ? "" : toDir + "/")\(title(to))"
        }
        guard added.count == removed.count, !added.isEmpty else { return nil }
        let oldDir = commonDirectory(removed), newDir = commonDirectory(added)
        var same = 0
        while same < oldDir.count, same < newDir.count,
              oldDir[oldDir.count - 1 - same] == newDir[newDir.count - 1 - same] { same += 1 }
        if same == 0 { return nil }
        func inside(_ paths: [String], _ dir: [String]) -> Set<String> {
            Set(paths.map { $0.split(separator: "/").dropFirst(dir.count).joined(separator: "/") })
        }
        if inside(removed, oldDir) != inside(added, newDir) { return nil }
        return "移动：\(oldDir[oldDir.count - same]) → \(folderLabel(newDir.prefix(newDir.count - same).joined(separator: "/")))"
    }

    private static func directory(of path: String) -> String {
        path.split(separator: "/").dropLast().joined(separator: "/")
    }

    private static func folderLabel(_ dir: String) -> String { dir.isEmpty ? "根目录" : dir }

    /// The deepest folder that contains every path (empty for the notebook root), as path components.
    private static func commonDirectory(_ paths: [String]) -> [String] {
        let dirs = paths.map { $0.split(separator: "/").dropLast().map(String.init) }
        var common = dirs[0]
        for dir in dirs {
            var n = 0
            while n < common.count, n < dir.count, common[n] == dir[n] { n += 1 }
            common = Array(common.prefix(n))
        }
        return common
    }

    static func title(_ path: String) -> String {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        for ext in [".md", ".markdown"] where name.lowercased().hasSuffix(ext) {
            return String(name.dropLast(ext.count))
        }
        return name
    }

    static func classify(_ error: Error) -> SyncError {
        if let error = error as? SyncError { return error }
        let message = (error as? GitError)?.message ?? error.localizedDescription
        let text = message.lowercased()
        let code = (error as? GitError)?.code
        if code == GIT_EAUTH.rawValue || ["authentication", "401", "403", "not authorized", "not permitted", "credentials"].contains(where: text.contains) {
            return SyncError(.auth, "账号授权无效或已过期，请到「云端账号」里重新连接")
        }
        // Checked before the network words below: its message says "SSL", but retrying won't help.
        if code == GIT_ECERTIFICATE.rawValue {
            return SyncError(.network, "无法验证云端的安全证书，请检查电脑时间和代理设置后重试（\(message)）")
        }
        if ["failed to resolve address", "could not resolve", "failed to connect", "connection refused", "timed out",
            "network is unreachable", "socket", "ssl", "tls", "connection reset"].contains(where: text.contains) {
            return SyncError(.network, "网络连接失败，请检查网络后重试")
        }
        if ["not found", "404", "does not appear to be a git repository"].contains(where: text.contains) {
            return SyncError(.notFound, "找不到云端的笔记本，可能已被删除，或这个账号没有权限")
        }
        if code == GIT_ECONFLICT.rawValue {
            return SyncError(.other, "有文件正在被修改，请稍后再同步")
        }
        return SyncError(.other, message)
    }
}

extension git_oid: @retroactive Equatable {
    public static func == (lhs: git_oid, rhs: git_oid) -> Bool {
        var a = lhs, b = rhs
        return git_oid_equal(&a, &b) == 1
    }
}

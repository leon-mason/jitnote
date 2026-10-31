import CGit2
import Foundation

/// One notebook = one ordinary Git working copy. Everything the app does to a notebook goes
/// through here, and everything ends up as plain Git objects, so any other Git client (or an
/// AI tool) can work on the same repository.
///
/// The same rules as the Android app (`NotebookGit.kt`), which the tests check case by case:
/// - commit local changes → fetch → merge (never rebase) → push; never force-push.
/// - a file changed on both sides keeps the version whose last change is newer
///   (ties go to the cloud); the other version stays in history and is recorded as a
///   `ConflictRecord` so the user can switch to it.
/// - a file deleted on one side and changed on the other is kept.
///
/// Not thread-safe: callers serialize access per notebook.
final class NotebookGit {
    static let remoteName = "origin"
    static let defaultBranch = "main"
    private static let maxAttempts = 3

    let workTree: URL

    init(workTree: URL) {
        Git2.initialize()
        self.workTree = workTree
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

    func sync(credentials: Credentials?, author: Author, device: String) throws -> SyncResult {
        do {
            return try withRepo { try syncInternal($0, credentials: credentials, author: author, device: device) }
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

    func readBlob(_ blob: String) throws -> Data {
        try withRepo { try blobData(Git2.oid(blob), in: $0) }
    }

    /// Overwrites [path] with its content at [commit] and commits that as a new change.
    @discardableResult
    func restore(_ path: String, commit: String, author: Author, device: String) throws -> Bool {
        try withRepo { repo in
            let content = try blobId(at: Git2.oid(commit), path: path, in: repo).map { try blobData($0, in: repo) }
            try writeOrDelete(path, content)
            try applyIdentity(repo, author)
            return try commitAllInternal(repo, author: author, device: device, message: "恢复历史版本：\(Self.title(path))")
        }
    }

    func conflicts() -> [ConflictRecord] {
        guard let data = try? Data(contentsOf: conflictFile) else { return [] }
        return (try? JSONDecoder().decode([ConflictRecord].self, from: data)) ?? []
    }

    func dismissConflict(_ path: String) throws {
        try saveConflicts(conflicts().filter { $0.path != path })
    }

    /// Replaces the kept version of a conflicted file with the one that was set aside.
    func useOtherVersion(_ record: ConflictRecord, author: Author, device: String) throws {
        try withRepo { repo in
            let content = try record.otherBlob.map { try blobData(Git2.oid($0), in: repo) }
            try writeOrDelete(record.path, content)
            try applyIdentity(repo, author)
            _ = try commitAllInternal(repo, author: author, device: device, message: "改用另一个版本：\(Self.title(record.path))")
        }
        try dismissConflict(record.path)
    }

    // MARK: - Sync internals

    private func syncInternal(_ repo: OpaquePointer, credentials: Credentials?, author: Author, device: String) throws -> SyncResult {
        try recover(repo)
        try applyIdentity(repo, author)
        _ = try commitAllInternal(repo, author: author, device: device, message: nil)
        let branch = try branchName(repo)
        var pulled = false
        var conflicts: [ConflictRecord] = []
        for _ in 0..<Self.maxAttempts {
            try fetch(repo, credentials: credentials)
            let remote = refId(repo, Self.remoteRef(branch))
            if let remote {
                let merge = try mergeRemote(repo, theirs: remote, branch: branch, author: author, device: device)
                pulled = pulled || merge.changed
                conflicts += merge.conflicts
            }
            guard let local = headId(repo), local != remote else {
                return SyncResult(pulled: pulled, pushed: false, conflicts: conflicts)
            }
            if try push(repo, branch: branch, credentials: credentials) {
                try ensureUpstream(repo, branch: branch)
                return SyncResult(pulled: pulled, pushed: true, conflicts: conflicts)
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
        let conflicts: [ConflictRecord]
    }

    private func mergeRemote(_ repo: OpaquePointer, theirs: git_oid, branch: String, author: Author, device: String) throws -> MergeOutcome {
        guard let head = headId(repo) else {
            // Nothing committed on this Mac yet: adopt the cloud's history as is.
            var ref: OpaquePointer?
            var target = theirs
            try Git2.check(git_reference_create(&ref, repo, "refs/heads/\(branch)", &target, 1, "sync: adopt cloud"))
            git_reference_free(ref)
            try checkoutHead(repo, force: true)
            return MergeOutcome(changed: true, conflicts: [])
        }
        if isAncestor(repo, theirs, of: head) { return MergeOutcome(changed: false, conflicts: []) }

        if isAncestor(repo, head, of: theirs) {
            try fastForward(repo, to: theirs, branch: branch)
            return MergeOutcome(changed: true, conflicts: [])
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
            let records = try resolveConflicts(repo, index: index, ours: head, theirs: theirs, author: author, device: device)
            return MergeOutcome(changed: true, conflicts: records)
        }
        try commitIndex(repo, index: index, parents: [head, theirs], author: author,
                        message: Self.commitMessage("同步：合并云端修改", device: device))
        return MergeOutcome(changed: true, conflicts: [])
    }

    private func resolveConflicts(
        _ repo: OpaquePointer,
        index: OpaquePointer,
        ours: git_oid,
        theirs: git_oid,
        author: Author,
        device: String
    ) throws -> [ConflictRecord] {
        let base = mergeBase(repo, ours, theirs)

        // "ours" = this Mac, "theirs" = cloud. A missing side means that side deleted the file.
        var stages: [(path: String, ours: git_oid?, theirs: git_oid?)] = []
        var iterator: OpaquePointer?
        try Git2.check(git_index_conflict_iterator_new(&iterator, index))
        var ancestor: UnsafePointer<git_index_entry>?
        var our: UnsafePointer<git_index_entry>?
        var their: UnsafePointer<git_index_entry>?
        while git_index_conflict_next(&ancestor, &our, &their, iterator) == 0 {
            guard let entry = our ?? their ?? ancestor else { continue }
            stages.append((String(cString: entry.pointee.path), our?.pointee.id, their?.pointee.id))
        }
        git_index_conflict_iterator_free(iterator)

        let now = Int64(Date().timeIntervalSince1970 * 1000)
        var records: [ConflictRecord] = []
        for stage in stages {
            if stage.ours == nil && stage.theirs == nil { continue }
            let oursTime = try lastChange(repo, tip: ours, base: base, path: stage.path)
            let theirsTime = try lastChange(repo, tip: theirs, base: base, path: stage.path)
            let keepLocal: Bool
            if stage.ours == nil {
                keepLocal = false
            } else if stage.theirs == nil {
                keepLocal = true
            } else {
                keepLocal = oursTime > theirsTime
            }
            let kept = (keepLocal ? stage.ours : stage.theirs)!
            try writeOrDelete(stage.path, blobData(kept, in: repo))
            try Git2.check(git_index_add_bypath(index, stage.path))
            let other = keepLocal ? stage.theirs : stage.ours
            records.append(ConflictRecord(
                path: stage.path,
                kept: keepLocal ? .local : .remote,
                keptTime: keepLocal ? oursTime : theirsTime,
                otherTime: keepLocal ? theirsTime : oursTime,
                otherBlob: other.map(Git2.string),
                otherCommit: Git2.string(keepLocal ? theirs : ours),
                createdAt: now
            ))
        }
        try Git2.check(git_index_write(index))
        try commitIndex(repo, index: index, parents: [ours, theirs], author: author,
                        message: Self.commitMessage("同步：合并云端修改（\(records.count) 个文件两边都改了，已采用较新版本）", device: device))

        try saveConflicts(conflicts().filter { old in !records.contains { $0.path == old.path } } + records)
        return records
    }

    /// Author time (ms) of the newest commit on [tip] that touched [path] after [base]; 0 if none.
    private func lastChange(_ repo: OpaquePointer, tip: git_oid, base: git_oid?, path: String) throws -> Int64 {
        try commits(repo, from: tip, hiding: base, touching: path, max: 1).first?.time ?? 0
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

    /// Leaves the repository in a clean state after a crash in the middle of a previous sync.
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

        var added: [String] = [], changed: [String] = [], removed: [String] = []
        let headTree = try headId(repo).map { try tree(of: $0, in: repo) }
        defer { headTree.map { git_tree_free($0) } }
        var diff: OpaquePointer?
        try Git2.check(git_diff_tree_to_index(&diff, repo, headTree, index, nil))
        defer { git_diff_free(diff) }
        for i in 0..<git_diff_num_deltas(diff) {
            let delta = git_diff_get_delta(diff, i)!.pointee
            switch delta.status {
            case GIT_DELTA_ADDED: added.append(String(cString: delta.new_file.path))
            case GIT_DELTA_DELETED: removed.append(String(cString: delta.old_file.path))
            default: changed.append(String(cString: delta.new_file.path))
            }
        }
        guard let summary = message ?? Self.describeChanges(added: added, changed: changed, removed: removed) else { return false }
        let parents = headId(repo).map { [$0] } ?? []
        try commitIndex(repo, index: index, parents: parents, author: author, message: Self.commitMessage(summary, device: device))
        return true
    }

    // MARK: - libgit2 helpers

    private var gitDir: URL { workTree.appendingPathComponent(".git") }

    private var conflictFile: URL { gitDir.appendingPathComponent("gitnotebook/conflicts.json") }

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

    private func mergeBase(_ repo: OpaquePointer, _ a: git_oid, _ b: git_oid) -> git_oid? {
        var out = git_oid(), first = a, second = b
        return git_merge_base(&out, repo, &first, &second) == 0 ? out : nil
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
    /// Like `git log -- path` without history simplification, which is what JGit does on Android.
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
        try Git2.check(git_index_write_tree(&treeId, index))
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

    private func applyIdentity(_ repo: OpaquePointer, _ author: Author) throws {
        try withConfig(repo) { config in
            if Self.configString(config, "user.name") == author.name && Self.configString(config, "user.email") == author.email { return }
            try Git2.check(git_config_set_string(config, "user.name", author.name))
            try Git2.check(git_config_set_string(config, "user.email", author.email))
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

    private func saveConflicts(_ list: [ConflictRecord]) throws {
        if list.isEmpty {
            try? FileManager.default.removeItem(at: conflictFile)
            return
        }
        try FileManager.default.createDirectory(at: conflictFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(list).write(to: conflictFile)
    }

    // MARK: - Statics

    /// Downloads [url] into [dir]. Works for empty repositories too.
    @discardableResult
    static func clone(url: String, into dir: URL, credentials: Credentials?, onProgress: ((Int, Int) -> Void)? = nil) throws -> NotebookGit {
        Git2.initialize()
        let context = TransferContext(credentials: credentials, onProgress: onProgress)
        var options = git_clone_options()
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
            try? FileManager.default.removeItem(at: dir)
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

    static func commitMessage(_ summary: String, device: String) -> String { "\(summary)\n\n来自 GitNotebook · \(device)" }

    /// Human-readable commit summary such as "编辑：读书笔记".
    static func describeChanges(added: [String], changed: [String], removed: [String]) -> String? {
        let total = added.count + changed.count + removed.count
        if total == 0 { return nil }
        if added.count == 1 && removed.count == 1 && changed.isEmpty {
            return "重命名：\(title(removed[0])) → \(title(added[0]))"
        }
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

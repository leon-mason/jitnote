import Foundation

/// When「启动时自动同步」should start a sync. See design.md「同步规则」.
enum AutoSync {
    /// A quick trip out (copy a line, a notification) must not lock the open note on "正在同步".
    /// A minute covers that. Coming back after writing on another device takes longer.
    static let minAwayMs: Int64 = 60_000

    /// `awayMs` is nil the first time the process comes forward, and on a duplicate foreground
    /// event with no background in between. `launchHandled` is true after that first event.
    static func shouldStart(enabled: Bool, busy: Bool, hasNotebook: Bool, awayMs: Int64?, launchHandled: Bool) -> Bool {
        guard enabled, !busy, hasNotebook else { return false }
        if let awayMs { return awayMs >= minAwayMs }
        return !launchHandled
    }
}

/// Everything the windows do with accounts and notebooks. Git work runs off the main thread,
/// one operation per notebook at a time. Mirrors `Notebooks.kt` on Android.
@MainActor
final class Notebooks: ObservableObject {
    struct SyncMessage: Equatable {
        let id = UUID()
        let notebookId: String
        let ok: Bool
        let text: String
    }

    @Published private(set) var state: AppState
    @Published private(set) var syncing: Set<String> = []
    /// The latest finished sync, shown once as a notice.
    @Published var syncMessage: SyncMessage?
    /// Bumped whenever files may have changed underneath the windows (sync, restore, ...).
    @Published private(set) var revision = 0
    /// A sync that stopped to ask which side wins; the window shows the question until it is answered.
    @Published private(set) var pendingSync: PendingSync?

    /// Files that both this Mac and the cloud changed, waiting for a choice before the sync goes on.
    struct PendingSync: Identifiable {
        let id = UUID()
        let notebook: Notebook
        let conflicts: [PendingConflict]
        /// Choices made in an earlier round that still apply (the cloud moved on while the user decided).
        let choices: [String: Side]
    }

    let root: URL
    let device: String
    let appVersion: String
    private let store: StateStore
    private var queues: [String: DispatchQueue] = [:]

    init(store: StateStore, root: URL, appVersion: String) {
        self.store = store
        self.root = root
        self.appVersion = appVersion
        state = store.state
        device = Host.current().localizedName ?? "Mac"
    }

    func notebook(_ id: String) -> Notebook? { state.notebooks.first { $0.id == id } }

    func account(_ id: String) -> Account? { state.accounts.first { $0.id == id } }

    func dir(_ notebook: Notebook) -> URL {
        notebook.folderPath.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? root.appendingPathComponent(notebook.dir, isDirectory: true)
    }

    func setCurrent(_ id: String) { update { $0.currentNotebookId = id } }

    // MARK: - A notebook whose folder is gone

    /// Bumped when it is worth looking again at whether notebook folders still exist (the window came
    /// forward, a drive may be back, a folder was pointed at again), so the windows re-check.
    @Published private(set) var folderChecks = 0

    func recheckFolders() { folderChecks += 1 }

    /// Points a notebook whose folder was moved at its new place. The folder must be that same notebook:
    /// not an arbitrary folder, so no way to change where a notebook lives, only to find it again.
    /// Whatever was not synced is in the folder, and stays.
    func relocate(_ notebook: Notebook, to folder: URL) async throws {
        let origin = try? await Self.background { try NotebookGit(workTree: folder).originUrl() }
        let others = state.notebooks.filter { $0.id != notebook.id }.map(dir)
        if let problem = NotebookFolders.relocationProblem(folder: folder, originUrl: origin ?? nil, expectedRemote: notebook.remoteUrl, otherNotebooks: others) {
            throw SyncError(.other, problem)
        }
        updateNotebook(notebook.id) {
            $0.folderPath = folder.path
            $0.folderChosen = !NotebookFolders.isInDefaultRoot(folder)
        }
        revision += 1
        folderChecks += 1
    }

    /// Downloads the notebook again into the place it used to be, when its folder cannot be found. Only into
    /// an empty or missing folder, and only when the folder above it still exists (see `redownloadProblem`).
    func redownload(_ notebook: Notebook, onProgress: @escaping (String) -> Void) async throws {
        let target = dir(notebook)
        let mayCreateParents = notebook.folderPath == nil || NotebookFolders.isInDefaultRoot(target)
        if let problem = NotebookFolders.redownloadProblem(target, mayCreateParents: mayCreateParents) { throw SyncError(.other, problem) }
        guard let account = account(notebook.accountId) else {
            throw SyncError(.auth, "这个笔记本用的云端账号已断开，请先到「云端账号」里重新连接")
        }
        onProgress("正在下载笔记本…")
        let credentials = try await credentials(account), url = notebook.remoteUrl
        try? FileManager.default.removeItem(at: target.appendingPathComponent(".DS_Store"))
        _ = try await Self.background {
            try NotebookGit.clone(url: url, into: target, credentials: credentials) { received, total in
                guard total > 0 else { return }
                let percent = received * 100 / total
                DispatchQueue.main.async { onProgress("正在下载笔记本… \(percent)%") }
            }
        }
        updateNotebook(notebook.id) {
            $0.lastSyncAt = nowMillis()
            $0.lastSyncError = nil
        }
        revision += 1
        folderChecks += 1
    }

    func setFileSort(_ sort: NoteSort) { update { $0.fileSort = sort } }

    func setExpandedFolders(_ notebookId: String, _ paths: Set<String>) {
        update { $0.expandedFolders[notebookId] = paths }
    }

    func setDefaultViewMode(_ mode: ViewMode) { update { $0.defaultViewMode = mode } }

    func setShowHiddenFiles(_ show: Bool) { update { $0.showHiddenFiles = show } }

    func setSyncOnLaunch(_ enabled: Bool) { update { $0.syncOnLaunch = enabled } }

    func touch() { revision += 1 }

    // MARK: - Accounts

    func addAccount(provider: Provider, token rawToken: String, username: String?, email: String?) async throws -> Account {
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let user: HostingApi.User
        if provider == .other {
            let login = (username ?? "").trimmingCharacters(in: .whitespaces)
            let mail = (email ?? "").trimmingCharacters(in: .whitespaces)
            user = HostingApi.User(login: login, email: mail.isEmpty ? "\(login)@users.noreply.jitnote" : mail)
        } else {
            user = try await HostingApi.verify(provider, token: token)
        }
        let existing = state.accounts.first { $0.provider == provider && $0.login == user.login }
        let account = Account(
            id: existing?.id ?? UUID().uuidString,
            provider: provider,
            login: user.login,
            email: user.email,
            createdAt: existing?.createdAt ?? nowMillis()
        )
        try TokenVault.save(token, account: account.id)
        update { s in s.accounts = s.accounts.filter { $0.id != account.id } + [account] }
        return account
    }

    func removeAccount(_ account: Account) {
        TokenVault.delete(account: account.id)
        update { s in s.accounts.removeAll { $0.id == account.id } }
    }

    // MARK: - Notebooks

    /// Creates a private repository in the cloud, downloads it into [folder] (an empty folder the user picked;
    /// nil for the default place) and records the notebook.
    func create(name: String, account: Account, repoPath: String, folder: URL? = nil, onProgress: @escaping (String) -> Void) async throws -> Notebook {
        let token = try await token(account)
        onProgress("正在云端创建笔记本…")
        var path = repoPath
        var created: HostingApi.CreatedRepo?
        for attempt in 1...3 {
            do {
                created = try await HostingApi.createPrivateRepo(account.provider, token: token, name: name, path: path)
                break
            } catch is HostingApi.NameTaken {
                if attempt == 3 { throw SyncError(.other, "仓库名已被占用") }
                path = "\(repoPath)-\(RepoNames.randomSuffix())"
            }
        }
        let notebook = try await download(name: name, account: account, url: created!.cloneUrl, folder: folder ?? NotebookFolders.defaultFolder(named: path), onProgress: onProgress)
        let meta = dir(notebook).appendingPathComponent(".jitnote/notebook.json")
        try FileManager.default.createDirectory(at: meta.deletingLastPathComponent(), withIntermediateDirectories: true)
        let info: [String: Any] = [
            "schema_version": 1,
            "id": notebook.id,
            "display_name": name,
            "created_at": ISO8601DateFormatter().string(from: Date()),
            "app_version": "Jitnote Mac \(appVersion)",
        ]
        try (JSONSerialization.data(withJSONObject: info, options: [.sortedKeys]) + Data("\n".utf8)).write(to: meta)
        let author = author(account), device = device
        _ = try await run(notebook) { try $0.commitAll(author: author, device: device, message: "新建笔记本：\(name)") }
        await sync(notebook)
        return notebook
    }

    /// Repositories in [account], each marked with whether it is already a notebook on this Mac.
    func listRemote(_ account: Account) async throws -> [(repo: HostingApi.RemoteRepo, isLocal: Bool)] {
        let local = Set(state.notebooks.map { Self.sameRepoKey($0.remoteUrl) })
        return try await HostingApi.listRepos(account.provider, token: await token(account))
            .map { ($0, local.contains(Self.sameRepoKey($0.cloneUrl))) }
    }

    /// Downloads an existing repository as a notebook, into [folder] (an empty folder the user picked; nil for the default place).
    func importNotebook(url: String, account: Account, name: String, folder: URL? = nil, onProgress: @escaping (String) -> Void) async throws -> Notebook {
        let trimmed = url.trimmingCharacters(in: .whitespaces)
        var notebook = try await download(name: name, account: account, url: trimmed, folder: folder ?? NotebookFolders.defaultFolder(named: Self.repoName(of: trimmed)), onProgress: onProgress)
        let meta = dir(notebook).appendingPathComponent(".jitnote/notebook.json")
        if name.trimmingCharacters(in: .whitespaces).isEmpty,
           let data = try? Data(contentsOf: meta),
           let display = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["display_name"] as? String {
            rename(notebook, to: display)
            notebook.name = display
        }
        return notebook
    }

    /// The repository's own name: the last part of its address, without ".git".
    static func repoName(of url: String) -> String {
        var name = url
        while name.hasSuffix("/") { name.removeLast() }
        name = name.components(separatedBy: "/").last ?? name
        if name.hasSuffix(".git") { name.removeLast(4) }
        return name
    }

    private func download(name: String, account: Account, url: String, folder: URL, onProgress: @escaping (String) -> Void) async throws -> Notebook {
        let id = UUID().uuidString
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        // Checked again here: the folder may have changed since the form looked at it.
        if let problem = NotebookFolders.problem(with: folder, otherNotebooks: state.notebooks.map(dir)) { throw SyncError(.other, problem) }
        let notebook = Notebook(
            id: id,
            name: trimmed.isEmpty ? Self.repoName(of: url) : trimmed,
            accountId: account.id,
            remoteUrl: url,
            dir: id,
            createdAt: nowMillis(),
            // A fresh download is, by definition, in sync with the cloud.
            lastSyncAt: nowMillis(),
            folderPath: folder.path,
            folderChosen: !NotebookFolders.isInDefaultRoot(folder)
        )
        onProgress("正在下载笔记本…")
        let credentials = try await credentials(account)
        let target = folder
        // Finder litter does not make a folder "not empty" for the user, but a download refuses to start in it.
        try? FileManager.default.removeItem(at: target.appendingPathComponent(".DS_Store"))
        _ = try await Self.background {
            try NotebookGit.clone(url: url, into: target, credentials: credentials) { received, total in
                guard total > 0 else { return }
                let percent = received * 100 / total
                DispatchQueue.main.async { onProgress("正在下载笔记本… \(percent)%") }
            }
        }
        update { $0.notebooks.append(notebook) }
        return notebook
    }

    func rename(_ notebook: Notebook, to name: String) {
        updateNotebook(notebook.id) { $0.name = name }
    }

    /// Removes the notebook from this Mac only. The cloud repository is left alone. The folder goes too,
    /// unless the user picked it: then whatever is in it, notes or not, stays exactly where it is.
    func deleteLocal(_ notebook: Notebook) async {
        let folder = dir(notebook)
        let removesFolder = !notebook.folderChosen
        try? await run(notebook) { _ in if removesFolder { try? FileManager.default.removeItem(at: folder) } }
        update { s in
            s.notebooks.removeAll { $0.id == notebook.id }
            s.expandedFolders[notebook.id] = nil
        }
        queues[notebook.id] = nil
    }

    func hasUnsyncedWork(_ notebook: Notebook) async -> Bool {
        (try? await run(notebook) { try $0.hasUnsyncedWork() }) ?? true
    }

    // MARK: - Unsynced work

    /// Notebooks with something that has not reached the cloud: edits on disk, or commits another tool
    /// made here. Versions are only recorded when syncing (design.md, "同步规则"), so this is what tells
    /// the user there is something to sync.
    @Published private(set) var unsynced: Set<String> = []
    private var refreshing: Set<String> = []
    private var refreshAgain: Set<String> = []

    /// Looks again at whether [notebook] has unsynced work. Calls that arrive while a check is running
    /// make it run once more, so the last change is never missed, without a check per keystroke.
    func refreshUnsynced(_ notebook: Notebook) async {
        if refreshing.contains(notebook.id) {
            refreshAgain.insert(notebook.id)
            return
        }
        refreshing.insert(notebook.id)
        defer { refreshing.remove(notebook.id) }
        repeat {
            refreshAgain.remove(notebook.id)
            // A failed check (say another tool holds the repository lock) keeps what was shown.
            guard let dirty = try? await run(notebook, { try $0.hasUnsyncedWork() }) else { continue }
            if dirty { unsynced.insert(notebook.id) } else { unsynced.remove(notebook.id) }
        } while refreshAgain.contains(notebook.id)
    }

    /// Records a version of just [paths] before the app deletes or overwrites them: with no commit
    /// between syncs, text that was never synced would otherwise be gone for good.
    func keepVersion(_ notebook: Notebook, paths: [String]) async {
        guard let account = account(notebook.accountId) else { return }
        let author = author(account), device = device
        _ = try? await run(notebook) { try $0.commitPaths(paths, author: author, device: device) }
    }

    private func queue(for notebook: Notebook) -> DispatchQueue {
        if let queue = queues[notebook.id] { return queue }
        let queue = DispatchQueue(label: "notebook.\(notebook.id)")
        queues[notebook.id] = queue
        return queue
    }

    /// Runs [body] on the notebook's own serial queue, so Git operations never overlap.
    func run<T>(_ notebook: Notebook, _ body: @escaping (NotebookGit) throws -> T) async throws -> T {
        let queue = queue(for: notebook)
        let git = NotebookGit(workTree: dir(notebook))
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try body(git) }) }
        }
    }

    // MARK: - Sync

    func isSyncing(_ notebook: Notebook) -> Bool { syncing.contains(notebook.id) }

    func startSync(_ notebook: Notebook, announceUnchanged: Bool = true) {
        guard !isSyncing(notebook) else { return }
        Task { await sync(notebook, announceUnchanged: announceUnchanged) }
    }

    private var backgroundAt: Int64?
    private var sawForeground = false

    /// The app is no longer the active one. A later [onForeground] may auto-sync. See design.md「同步规则」.
    func onBackground() {
        // A resign that arrives before the first activate is not "the user left".
        guard sawForeground else { return }
        backgroundAt = nowMillis()
    }

    /// The app is active again: a cold start, or a return from another app. Does nothing unless the setting is on.
    func onForeground() {
        let away = backgroundAt.map { nowMillis() - $0 }
        backgroundAt = nil
        let handled = sawForeground
        sawForeground = true
        guard let notebook = state.currentNotebook else { return }
        let busy = isSyncing(notebook) || pendingSync != nil || NotebookFolders.isMissing(dir(notebook))
        guard AutoSync.shouldStart(enabled: state.syncOnLaunch, busy: busy, hasNotebook: true, awayMs: away, launchHandled: handled) else { return }
        startSync(notebook, announceUnchanged: false)
    }

    private static let folderGoneMessage = "找不到这个笔记本的文件夹，没法同步。请先在笔记本页面里找回它，或者重新下载。"

    /// Goes on with a sync that asked a question, using the user's answers.
    func continueSync(_ choices: [String: Side]) {
        guard let pending = pendingSync, !isSyncing(pending.notebook) else { return }
        pendingSync = nil
        Task { await sync(pending.notebook, choices: choices) }
    }

    /// The user would rather not decide now. Nothing was merged or uploaded; the next sync asks again.
    func cancelPendingSync() {
        guard let pending = pendingSync else { return }
        pendingSync = nil
        syncMessage = SyncMessage(notebookId: pending.notebook.id, ok: false, text: "已取消同步。两边的修改都还在，下次同步时再选择。")
    }

    private func sync(_ notebook: Notebook, choices: [String: Side] = [:], announceUnchanged: Bool = true) async {
        // Never "sync" a folder that is not there: nothing in it to upload, and a fresh empty one must not appear.
        if NotebookFolders.isMissing(dir(notebook)) {
            folderChecks += 1
            syncMessage = SyncMessage(notebookId: notebook.id, ok: false, text: Self.folderGoneMessage)
            return
        }
        syncing.insert(notebook.id)
        defer {
            syncing.remove(notebook.id)
            revision += 1
        }
        do {
            guard let account = account(notebook.accountId) else {
                throw SyncError(.auth, "这个笔记本用的云端账号已断开，请重新连接")
            }
            let credentials = try await credentials(account), author = author(account), device = device
            let result = try await run(notebook) {
                try $0.sync(credentials: credentials, author: author, device: device, choices: choices)
            }
            if !result.pending.isEmpty {
                // Not finished: no "synced" time and no message, just the question.
                pendingSync = PendingSync(
                    notebook: notebook,
                    conflicts: result.pending,
                    choices: choices.filter { choice in result.pending.contains { $0.path == choice.key } }
                )
            } else {
                updateNotebook(notebook.id) {
                    $0.lastSyncAt = nowMillis()
                    $0.lastSyncError = nil
                }
                // An automatic sync that changed nothing stays quiet. A manual one still says "已是最新".
                let unchanged = result.resolved == 0 && !result.pulled && !result.pushed
                if announceUnchanged || !unchanged {
                    syncMessage = SyncMessage(notebookId: notebook.id, ok: true, text: Self.describe(result))
                }
            }
        } catch {
            let message = NotebookGit.classify(error).message
            updateNotebook(notebook.id) { $0.lastSyncError = message }
            syncMessage = SyncMessage(notebookId: notebook.id, ok: false, text: message)
        }
        await refreshUnsynced(notebook)
    }

    private static func describe(_ result: SyncResult) -> String {
        if result.resolved > 0 { return "已同步。\(result.resolved) 个文件两边都改了，已按你的选择处理" }
        switch (result.pulled, result.pushed) {
        case (true, true): return "已同步：收到云端修改，并上传了本机修改"
        case (true, false): return "已同步：收到云端修改"
        case (false, true): return "已同步：已上传本机修改"
        default: return "已是最新"
        }
    }

    // MARK: - History

    func history(_ notebook: Notebook, path: String) async throws -> [Version] {
        try await run(notebook) { try $0.history(path) }
    }

    func read(_ notebook: Notebook, path: String, at commit: String) async throws -> Data? {
        try await run(notebook) { try $0.read(at: commit, path: path) }
    }

    func restore(_ notebook: Notebook, path: String, commit: String) async throws {
        guard let account = account(notebook.accountId) else { return }
        let author = author(account), device = device
        try await run(notebook) { try $0.restore(path, commit: commit, author: author, device: device) }
        revision += 1
    }

    // MARK: - Helpers

    private func update(_ transform: (inout AppState) -> Void) {
        store.update(transform)
        state = store.state
    }

    private func updateNotebook(_ id: String, _ transform: (inout Notebook) -> Void) {
        update { s in
            if let i = s.notebooks.firstIndex(where: { $0.id == id }) { transform(&s.notebooks[i]) }
        }
    }

    private func author(_ account: Account) -> Author { Author(name: account.login, email: account.email) }

    private func token(_ account: Account) async throws -> String {
        let id = account.id
        guard let token = try await Self.background({ try TokenVault.load(account: id) }) else {
            throw SyncError(.auth, "找不到这个账号的令牌，请到「云端账号」里重新连接")
        }
        return token
    }

    private func credentials(_ account: Account) async throws -> Credentials {
        Credentials(username: account.login, password: try await token(account))
    }

    private static func sameRepoKey(_ url: String) -> String { RepoUrls.key(of: url) }

    private static func background<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(with: Result { try body() }) }
        }
    }
}

import Foundation

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

    func dir(_ notebook: Notebook) -> URL { root.appendingPathComponent(notebook.dir, isDirectory: true) }

    func setCurrent(_ id: String) { update { $0.currentNotebookId = id } }

    func setSort(_ sort: NoteSort) { update { $0.noteSort = sort } }

    func setShowHiddenFiles(_ show: Bool) { update { $0.showHiddenFiles = show } }

    func touch() { revision += 1 }

    // MARK: - Accounts

    func addAccount(provider: Provider, token rawToken: String, username: String?, email: String?) async throws -> Account {
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let user: HostingApi.User
        if provider == .other {
            let login = (username ?? "").trimmingCharacters(in: .whitespaces)
            let mail = (email ?? "").trimmingCharacters(in: .whitespaces)
            user = HostingApi.User(login: login, email: mail.isEmpty ? "\(login)@users.noreply.gitnotebook" : mail)
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

    /// Creates a private repository in the cloud, downloads it and records the notebook.
    func create(name: String, account: Account, repoPath: String, onProgress: @escaping (String) -> Void) async throws -> Notebook {
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
        let notebook = try await download(name: name, account: account, url: created!.cloneUrl, onProgress: onProgress)
        let meta = dir(notebook).appendingPathComponent(".gitnote/notebook.json")
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

    /// Downloads an existing repository as a notebook.
    func importNotebook(url: String, account: Account, name: String, onProgress: @escaping (String) -> Void) async throws -> Notebook {
        var notebook = try await download(name: name, account: account, url: url.trimmingCharacters(in: .whitespaces), onProgress: onProgress)
        let meta = dir(notebook).appendingPathComponent(".gitnote/notebook.json")
        if name.trimmingCharacters(in: .whitespaces).isEmpty,
           let data = try? Data(contentsOf: meta),
           let display = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["display_name"] as? String {
            rename(notebook, to: display)
            notebook.name = display
        }
        return notebook
    }

    private func download(name: String, account: Account, url: String, onProgress: @escaping (String) -> Void) async throws -> Notebook {
        let id = UUID().uuidString
        var fallback = url
        while fallback.hasSuffix("/") { fallback.removeLast() }
        fallback = fallback.components(separatedBy: "/").last ?? fallback
        if fallback.hasSuffix(".git") { fallback.removeLast(4) }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let notebook = Notebook(
            id: id,
            name: trimmed.isEmpty ? fallback : trimmed,
            accountId: account.id,
            remoteUrl: url,
            dir: id,
            createdAt: nowMillis(),
            // A fresh download is, by definition, in sync with the cloud.
            lastSyncAt: nowMillis()
        )
        onProgress("正在下载笔记本…")
        let credentials = try await credentials(account)
        let target = dir(notebook)
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

    /// Removes the notebook from this Mac only. The cloud repository is left alone.
    func deleteLocal(_ notebook: Notebook) async {
        let folder = dir(notebook)
        try? await run(notebook) { _ in try? FileManager.default.removeItem(at: folder) }
        update { s in s.notebooks.removeAll { $0.id == notebook.id } }
        queues[notebook.id] = nil
    }

    func hasUnsyncedWork(_ notebook: Notebook) async -> Bool {
        (try? await run(notebook) { try $0.hasUnsyncedWork() }) ?? true
    }

    // MARK: - Editing

    /// Commits whatever changed in the working copy, e.g. after leaving a note.
    func commitInBackground(_ notebook: Notebook) {
        Task { _ = await commit(notebook) }
    }

    @discardableResult
    func commit(_ notebook: Notebook, message: String? = nil) async -> Bool {
        guard let account = account(notebook.accountId) else { return false }
        let author = author(account), device = device
        return (try? await run(notebook) { try $0.commitAll(author: author, device: device, message: message) }) ?? false
    }

    /// Records a version of every notebook with changes, before returning; used when the app quits.
    func commitAllNow() {
        for notebook in state.notebooks {
            guard let account = account(notebook.accountId) else { continue }
            let git = NotebookGit(workTree: dir(notebook)), author = author(account), device = device
            queue(for: notebook).sync { _ = try? git.commitAll(author: author, device: device) }
        }
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

    func startSync(_ notebook: Notebook) {
        guard !isSyncing(notebook) else { return }
        Task { await sync(notebook) }
    }

    private func sync(_ notebook: Notebook) async {
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
            let result = try await run(notebook) { try $0.sync(credentials: credentials, author: author, device: device) }
            updateNotebook(notebook.id) {
                $0.lastSyncAt = nowMillis()
                $0.lastSyncError = nil
            }
            syncMessage = SyncMessage(notebookId: notebook.id, ok: true, text: Self.describe(result))
        } catch {
            let message = NotebookGit.classify(error).message
            updateNotebook(notebook.id) { $0.lastSyncError = message }
            syncMessage = SyncMessage(notebookId: notebook.id, ok: false, text: message)
        }
    }

    private static func describe(_ result: SyncResult) -> String {
        if !result.conflicts.isEmpty { return "已同步。\(result.conflicts.count) 个文件两边都改了，已采用较新版本" }
        switch (result.pulled, result.pushed) {
        case (true, true): return "已同步：收到云端修改，并上传了本机修改"
        case (true, false): return "已同步：收到云端修改"
        case (false, true): return "已同步：已上传本机修改"
        default: return "已是最新"
        }
    }

    // MARK: - History and conflicts

    func conflicts(_ notebook: Notebook) async -> [ConflictRecord] {
        (try? await run(notebook) { $0.conflicts() }) ?? []
    }

    func useOtherVersion(_ notebook: Notebook, _ record: ConflictRecord) async throws {
        guard let account = account(notebook.accountId) else { return }
        let author = author(account), device = device
        try await run(notebook) { try $0.useOtherVersion(record, author: author, device: device) }
        revision += 1
    }

    func dismissConflict(_ notebook: Notebook, _ record: ConflictRecord) async {
        try? await run(notebook) { try $0.dismissConflict(record.path) }
    }

    func history(_ notebook: Notebook, path: String) async throws -> [Version] {
        try await run(notebook) { try $0.history(path) }
    }

    func read(_ notebook: Notebook, path: String, at commit: String) async throws -> Data? {
        try await run(notebook) { try $0.read(at: commit, path: path) }
    }

    func restore(_ notebook: Notebook, path: String, commit: String) async throws {
        guard let account = account(notebook.accountId) else { return }
        let author = author(account), device = device
        _ = try await run(notebook) { try $0.restore(path, commit: commit, author: author, device: device) }
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

    private static func sameRepoKey(_ url: String) -> String {
        var key = url.trimmingCharacters(in: .whitespaces).lowercased()
        while key.hasSuffix("/") { key.removeLast() }
        if key.hasSuffix(".git") { key.removeLast(4) }
        return key
    }

    private static func background<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(with: Result { try body() }) }
        }
    }
}

import AppKit
import SwiftUI

/// The Settings window (⌘,): notebooks, cloud accounts, and updates.
struct SettingsView: View {
    @State private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettingsView().tabItem { Label("通用", systemImage: "gearshape") }.tag("general")
            ManageNotebooksView().tabItem { Label("笔记本", systemImage: "books.vertical") }.tag("notebooks")
            AccountsView().tabItem { Label("云端账号", systemImage: "person.crop.circle") }.tag("accounts")
            AboutView().tabItem { Label("关于", systemImage: "info.circle") }.tag("about")
        }
        .frame(width: 560, height: 420)
        #if GN_DEBUG_HOOKS
        .onReceive(NotificationCenter.default.publisher(for: .debugCommand)) { note in
            if let command = note.object as? String, command.hasPrefix("tab ") { tab = String(command.dropFirst(4)) }
        }
        #endif
    }
}

struct GeneralSettingsView: View {
    @EnvironmentObject private var notebooks: Notebooks

    var body: some View {
        Form {
            Toggle(isOn: Binding(get: { notebooks.state.showHiddenFiles }, set: notebooks.setShowHiddenFiles)) {
                Text("显示隐藏文件")
                Text("显示以 . 开头的文件和文件夹，比如 .obsidian、.gitignore。Git 自己的 .git 文件夹始终不显示。")
            }
            Toggle(isOn: Binding(get: { notebooks.state.syncOnLaunch }, set: notebooks.setSyncOnLaunch)) {
                Text("启动时自动同步")
                Text("打开 App，或离开超过一分钟后再回来，自动同步当前笔记本。没有变化时不提示。")
            }
            Picker(selection: Binding(get: { notebooks.state.defaultViewMode }, set: notebooks.setDefaultViewMode)) {
                Text("编辑").tag(ViewMode.edit)
                Text("预览").tag(ViewMode.preview)
            } label: {
                Text("打开笔记时默认为")
                Text("新建的笔记和纯文本文件总是编辑。")
            }
        }
        .formStyle(.grouped)
    }
}

/// Add, rename, remove and sync notebooks (the Android app's notebook list).
struct ManageNotebooksView: View {
    @EnvironmentObject private var notebooks: Notebooks
    @State private var adding = false
    @State private var renaming: Notebook?
    @State private var removing: (notebook: Notebook, unsynced: Bool)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if notebooks.state.notebooks.isEmpty {
                Text("还没有笔记本。").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(notebooks.state.notebooks) { notebook in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(notebook.name).font(.headline)
                            if notebooks.folderChecks >= 0 && NotebookFolders.isMissing(notebooks.dir(notebook)) {
                                Label("找不到这个笔记本的文件夹", systemImage: "folder.badge.questionmark")
                                    .font(.caption).foregroundStyle(.orange)
                            } else {
                                SyncStatusLine(notebook: notebook, syncing: notebooks.isSyncing(notebook), unsynced: notebooks.unsynced.contains(notebook.id))
                            }
                        }
                        Spacer()
                        if notebook.id == notebooks.state.currentNotebook?.id {
                            Text("正在看").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Button("打开") { notebooks.setCurrent(notebook.id) }
                        }
                        Button { notebooks.startSync(notebook) } label: { Image(systemName: "arrow.triangle.2.circlepath") }
                            .disabled(notebooks.isSyncing(notebook))
                            .help("同步")
                        Menu {
                            Button("重命名…") { renaming = notebook }
                            Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([notebooks.dir(notebook)]) }
                            Button("复制路径") { copyToPasteboard(notebooks.dir(notebook).path) }
                            Divider()
                            Button("从这台电脑移除…", role: .destructive) {
                                Task { removing = (notebook, await notebooks.hasUnsyncedWork(notebook)) }
                            }
                        } label: { Image(systemName: "ellipsis.circle") }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                    }
                    .padding(.vertical, 4)
                }
                .task { for notebook in notebooks.state.notebooks { await notebooks.refreshUnsynced(notebook) } }
            }
            Divider()
            HStack {
                Button("添加笔记本…") { adding = true }.disabled(notebooks.state.accounts.isEmpty)
                if notebooks.state.accounts.isEmpty { Text("请先在「云端账号」里连接账号").foregroundStyle(.secondary).font(.caption) }
                Spacer()
            }
            .padding(12)
        }
        .sheet(isPresented: $adding) { AddNotebookView { adding = false } }
        .sheet(item: $renaming) { notebook in
            TextPrompt(title: "重命名笔记本", label: "笔记本名称", initial: notebook.name, onCancel: { renaming = nil }) { name in
                let trimmed = name.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { return "名称不能为空" }
                notebooks.rename(notebook, to: trimmed)
                renaming = nil
                return nil
            }
        }
        .alert("从这台电脑移除「\(removing?.notebook.name ?? "")」？",
               isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("移除", role: .destructive) {
                if let notebook = removing?.notebook { Task { await notebooks.deleteLocal(notebook) } }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(removalMessage)
        }
    }

    /// What removing does to the folder depends on who chose it (design.md, "笔记本文件夹"), and so does what
    /// is lost: a folder the user chose stays, with any unsynced edits still in it.
    private var removalMessage: String {
        guard let removing else { return "" }
        let path = notebooks.dir(removing.notebook).path
        if removing.notebook.folderChosen {
            return (removing.unsynced
                ? "这个笔记本还有没同步到云端的修改，移除后它们不会再同步，但仍留在文件夹里。建议先点同步。\n\n"
                : "")
                + "你选的文件夹「\(path)」和里面的所有文件会原样留在原处，App 不会删除任何东西。\n\n云端的笔记也不会被删除。以后想再添加它，要选一个新的空文件夹。"
        }
        return (removing.unsynced ? "这个笔记本还有没同步到云端的修改，移除后这些修改会丢失。建议先点同步。\n\n" : "")
            + "这台电脑上的文件夹「\(path)」和里面的所有文件会一起删除。\n\n云端的笔记不会被删除，以后可以重新下载。"
    }
}

struct AccountsView: View {
    @EnvironmentObject private var notebooks: Notebooks
    @State private var adding = false
    @State private var removing: Account?
    @State private var blocked = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if notebooks.state.accounts.isEmpty {
                VStack(spacing: 8) {
                    Text("还没有连接账号").font(.headline)
                    Text("连接 Gitee 或 GitHub 账号后，笔记会保存到你自己的账号里。").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(notebooks.state.accounts) { account in
                    let used = notebooks.state.notebooks.filter { $0.accountId == account.id }.count
                    HStack {
                        VStack(alignment: .leading) {
                            Text("\(account.provider.label) · \(account.login)").font(.headline)
                            Text(used > 0 ? "\(used) 个笔记本在用" : "没有笔记本在用").foregroundStyle(.secondary).font(.caption)
                        }
                        Spacer()
                        Button("断开…") {
                            if used > 0 { blocked = true } else { removing = account }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            Divider()
            HStack {
                Button("连接账号…") { adding = true }
                Spacer()
            }
            .padding(12)
        }
        .sheet(isPresented: $adding) { AddAccountView { adding = false } }
        .alert("还有笔记本在用这个账号", isPresented: $blocked) {
            Button("知道了") {}
        } message: {
            Text("请先在「笔记本」里把用到它的笔记本从这台电脑移除，再断开账号。\n如果只是授权过期了，直接点「连接账号」重新连接同一个账号即可。")
        }
        .alert("断开 \(removing?.login ?? "")？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("断开", role: .destructive) { if let removing { notebooks.removeAccount(removing) } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这台电脑会删除保存的授权，云端账号和笔记不受影响。")
        }
    }
}

/// Connect a Gitee / GitHub account with a personal access token, or any Git host with a password.
struct AddAccountView: View {
    let onDone: () -> Void
    @EnvironmentObject private var notebooks: Notebooks
    @State private var provider = Provider.gitee
    @State private var username = ""
    @State private var email = ""
    @State private var token = ""
    @State private var busy = false
    @State private var error: String?

    private var canSubmit: Bool {
        !token.trimmingCharacters(in: .whitespaces).isEmpty && (provider != .other || !username.trimmingCharacters(in: .whitespaces).isEmpty) && !busy
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("连接云端账号").font(.title2.weight(.semibold))
            Text("笔记保存在哪里？").font(.headline)
            Picker("", selection: $provider) {
                Text("Gitee").tag(Provider.gitee)
                Text("GitHub").tag(Provider.github)
                Text("其他").tag(Provider.other)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    switch provider {
                    case .gitee:
                        Text("Gitee（码云）国内访问快，推荐。").fontWeight(.medium)
                        Text("1. 还没有 Gitee 账号的话，先在 gitee.com 免费注册一个。")
                        Text("2. 点下面的按钮，登录后会打开「生成私人令牌」页面。")
                        Button("打开 Gitee 生成页面") { open("https://gitee.com/profile/personal_access_tokens/new") }
                        Text("3. 描述随便填（比如“笔记”），权限保持默认勾选，点「提交」。")
                        Text("4. 复制页面上显示的一长串字符，粘贴到下面。")
                    case .github:
                        Text("GitHub 在国内有时连接不稳定。").fontWeight(.medium)
                        Text("1. 点下面的按钮，登录 GitHub 后会打开生成令牌的页面（已帮你勾好需要的权限）。")
                        Button("打开 GitHub 生成页面") { open("https://github.com/settings/tokens/new?scopes=repo&description=Jitnote") }
                        Text("2. Expiration（有效期）建议选 No expiration（不过期），拉到页面底部点 Generate token。")
                        Text("3. 复制以 ghp_ 开头的那串字符，粘贴到下面。")
                    case .other:
                        Text("适合自己搭建的 Gitea、GitLab 等服务。").fontWeight(.medium)
                        Text("填写登录用户名，以及密码或访问令牌。这种方式只能下载已经存在的笔记本，不能在这里新建。")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            Form {
                if provider == .other {
                    TextField("用户名", text: $username)
                    TextField("邮箱（可不填）", text: $email)
                }
                SecureField(provider == .other ? "密码或访问令牌" : "粘贴令牌", text: $token)
            }
            Text("令牌只保存在这台电脑的钥匙串里，不会发给任何第三方。").font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red) }

            HStack {
                Spacer()
                Button("以后再说", role: .cancel, action: onDone).keyboardShortcut(.cancelAction)
                Button(busy ? "正在验证…" : "连接", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private func open(_ url: String) { NSWorkspace.shared.open(URL(string: url)!) }

    private func submit() {
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                _ = try await notebooks.addAccount(provider: provider, token: token, username: username, email: email)
                onDone()
            } catch {
                self.error = "连接失败：\(error.localizedDescription)"
            }
        }
    }
}

/// Create a new notebook in the cloud, or turn a repository that already exists into one.
struct AddNotebookView: View {
    let onDone: () -> Void
    @EnvironmentObject private var notebooks: Notebooks
    @State private var mode = 0
    @State private var busy: String?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("添加笔记本").font(.title2.weight(.semibold))
            Picker("", selection: $mode) {
                Text("新建").tag(0)
                Text("用已有的").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(busy != nil)

            if let busy {
                Waiting(message: busy).frame(height: 240)
            } else if mode == 0 {
                CreateNotebookForm(onCreate: run)
            } else {
                ExistingNotebookForm(onImport: run)
            }
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("取消", role: .cancel, action: onDone).keyboardShortcut(.cancelAction).disabled(busy != nil)
            }
        }
        .padding(24)
        .frame(width: 560, height: 560, alignment: .top)
    }

    private func run(_ action: @escaping (@escaping (String) -> Void) async throws -> Notebook) {
        error = nil
        busy = "请稍候…"
        Task {
            defer { busy = nil }
            do {
                let notebook = try await action { busy = $0 }
                notebooks.setCurrent(notebook.id)
                onDone()
            } catch {
                self.error = error.localizedDescription.isEmpty ? "出错了，请重试" : error.localizedDescription
            }
        }
    }
}

/// Where a new notebook goes on this Mac: the default place, or an empty folder the user picks. Shown when a
/// notebook is created or downloaded; there is no way to change it afterwards (design.md, "笔记本文件夹").
private struct FolderChoice: View {
    let defaultFolder: URL
    /// nil while the default place is in use.
    @Binding var picked: URL?
    @EnvironmentObject private var notebooks: Notebooks

    private var folder: URL { picked ?? defaultFolder }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("保存位置").foregroundStyle(.secondary)
                Text(abbreviated(folder)).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("更改…", action: choose)
                if picked != nil { Button("用默认位置") { picked = nil }.buttonStyle(.link) }
            }
            if let problem = NotebookFolders.problem(with: folder, otherNotebooks: notebooks.state.notebooks.map(notebooks.dir)) {
                Text(problem).font(.caption).foregroundStyle(.red)
            } else if let warning = NotebookFolders.syncWarning(for: folder) {
                Text(warning).font(.caption).foregroundStyle(.orange)
            }
            Text("笔记本里的所有文件都在这个文件夹里。创建后不能更改位置。").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func abbreviated(_ url: URL) -> String { (url.path as NSString).abbreviatingWithTildeInPath }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        panel.message = "选一个空文件夹，笔记本会放在里面。没有合适的，点「新建文件夹」。"
        let start = folder.deletingLastPathComponent()
        panel.directoryURL = FileManager.default.fileExists(atPath: start.path) ? start : URL(fileURLWithPath: NSHomeDirectory())
        if panel.runModal() == .OK, let url = panel.url { picked = url }
    }
}

/// Puts [text] on the clipboard, e.g. a notebook's folder path to paste into an AI tool as its project folder.
func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

private struct AccountPicker: View {
    let accounts: [Account]
    @Binding var selection: String?

    var body: some View {
        if accounts.count > 1 {
            Picker("保存到", selection: $selection) {
                ForEach(accounts) { Text("\($0.provider.label) · \($0.login)").tag(Optional($0.id)) }
            }
        }
    }
}

private struct CreateNotebookForm: View {
    let onCreate: (@escaping (@escaping (String) -> Void) async throws -> Notebook) -> Void
    @EnvironmentObject private var notebooks: Notebooks
    @State private var accountId: String?
    @State private var name = ""
    @State private var path = ""
    @State private var pathEdited = false
    @State private var advanced = false
    @State private var pickedFolder: URL?

    private var folder: URL { pickedFolder ?? NotebookFolders.defaultFolder(named: path) }
    private var creatable: [Account] { notebooks.state.accounts.filter { $0.provider.canCreateRepos } }
    private var account: Account? { creatable.first { $0.id == accountId } ?? creatable.first }

    var body: some View {
        if creatable.isEmpty {
            Text("「其他」类型的账号只能用已有的仓库，请切到「用已有的」。想新建的话，请先连接 Gitee 或 GitHub 账号。")
                .foregroundStyle(.secondary)
        } else {
            Form {
                AccountPicker(accounts: creatable, selection: $accountId)
                TextField("笔记本名称", text: $name, prompt: Text("比如：读书笔记、工作日志"))
                    .onChange(of: name) { _, value in if !pathEdited { path = RepoNames.fromName(value) } }
                DisclosureGroup("高级选项", isExpanded: $advanced) {
                    TextField("云端仓库名（英文）", text: Binding(get: { path }, set: { path = $0; pathEdited = true }))
                    Text("只能用英文字母、数字和 - _ .，以字母开头。一般不用改。").font(.caption).foregroundStyle(.secondary)
                }
            }
            FolderChoice(defaultFolder: NotebookFolders.defaultFolder(named: path), picked: $pickedFolder)
            Text("会在你的 \(account?.provider.label ?? "") 账号里建一个只有你自己能看到的存储空间。").foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("创建") {
                    guard let account else { return }
                    let name = name.trimmingCharacters(in: .whitespaces), path = path, folder = folder
                    onCreate { progress in try await notebooks.create(name: name, account: account, repoPath: path, folder: folder, onProgress: progress) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || !RepoNames.isValid(path)
                    || NotebookFolders.problem(with: folder, otherNotebooks: notebooks.state.notebooks.map(notebooks.dir)) != nil)
            }
        }
    }
}

private struct ExistingNotebookForm: View {
    let onImport: (@escaping (@escaping (String) -> Void) async throws -> Notebook) -> Void
    @EnvironmentObject private var notebooks: Notebooks
    @State private var accountId: String?
    @State private var repos: [(repo: HostingApi.RemoteRepo, isLocal: Bool)]?
    @State private var loadError: String?
    @State private var search = ""
    @State private var picked: HostingApi.RemoteRepo?
    @State private var useUrl = false
    @State private var url = ""
    @State private var name = ""
    @State private var pickedFolder: URL?

    private var account: Account? { notebooks.state.accounts.first { $0.id == accountId } ?? notebooks.state.accounts.first }

    private func folder(forCloneUrl cloneUrl: String) -> URL { pickedFolder ?? NotebookFolders.defaultFolder(named: Notebooks.repoName(of: cloneUrl)) }

    private func canStart(_ cloneUrl: String) -> Bool {
        NotebookFolders.problem(with: folder(forCloneUrl: cloneUrl), otherNotebooks: notebooks.state.notebooks.map(notebooks.dir)) == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            AccountPicker(accounts: notebooks.state.accounts, selection: $accountId)
            if let picked {
                confirm(picked)
            } else if useUrl || account?.provider == .other {
                byUrl
            } else {
                list
            }
        }
        .task(id: account?.id) { await load() }
    }

    @ViewBuilder
    private var list: some View {
        if let loadError {
            Text("没能读取账号里的内容：\(loadError)").foregroundStyle(.red)
            Button("重试") { Task { await load() } }
        } else if let repos {
            if repos.isEmpty {
                Text("没有找到任何仓库。可以回到「新建」建一个新的笔记本。").foregroundStyle(.secondary)
            } else {
                Text("选一个你 \(account?.provider.label ?? "") 账号里已有的仓库，它会直接变成笔记本。").foregroundStyle(.secondary)
                if repos.count > 6 { TextField("搜索名字", text: $search).textFieldStyle(.roundedBorder) }
                let shown = repos.filter { search.isEmpty || $0.repo.displayName.localizedCaseInsensitiveContains(search) || $0.repo.path.localizedCaseInsensitiveContains(search) }
                List(shown, id: \.repo.id) { item in
                    Button { if !item.isLocal { picked = item.repo; name = item.repo.displayName } } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.repo.displayName).font(.headline)
                            Text(details(item.repo, isLocal: item.isLocal)).font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(item.isLocal)
                }
                .frame(minHeight: 200)
            }
            Button("列表里没有？手动填写网址") { useUrl = true }.buttonStyle(.link)
        } else {
            Waiting(message: "正在读取你 \(account?.provider.label ?? "") 账号里的内容…").frame(height: 200)
        }
    }

    private var byUrl: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("在浏览器里打开仓库页面，复制地址栏里的网址，粘贴到这里。").foregroundStyle(.secondary)
            TextField("网址", text: $url, prompt: Text("https://gitee.com/用户名/仓库")).textFieldStyle(.roundedBorder)
            TextField("在 App 里叫什么（可不填）", text: $name).textFieldStyle(.roundedBorder)
            FolderChoice(defaultFolder: NotebookFolders.defaultFolder(named: Notebooks.repoName(of: RepoUrls.toCloneUrl(url))), picked: $pickedFolder)
            HStack {
                if account?.provider != .other { Button("从账号里选") { useUrl = false }.buttonStyle(.link) }
                Spacer()
                Button("开始下载") { start(RepoUrls.toCloneUrl(url)) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!url.trimmingCharacters(in: .whitespaces).hasPrefix("http") || !canStart(RepoUrls.toCloneUrl(url)))
            }
        }
    }

    private func confirm(_ repo: HostingApi.RemoteRepo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("把「\(repo.displayName)」变成笔记本").font(.headline)
            Text("里面原有的文件都会原样保留，在电脑上写的笔记也会同步回去。").foregroundStyle(.secondary)
            if !repo.isPrivate { Text("注意：这个仓库是公开的，所有人都能看到里面的笔记。").foregroundStyle(.orange) }
            if let size = repo.sizeKb, size > 50 * 1024 {
                Text("这个仓库比较大（约 \(size / 1024) MB），第一次下载会花一些时间。").foregroundStyle(.orange)
            }
            TextField("在 App 里叫什么", text: $name).textFieldStyle(.roundedBorder)
            FolderChoice(defaultFolder: NotebookFolders.defaultFolder(named: Notebooks.repoName(of: repo.cloneUrl)), picked: $pickedFolder)
            HStack {
                Button("换一个") { picked = nil }.buttonStyle(.link)
                Spacer()
                Button("开始下载") { start(repo.cloneUrl) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canStart(repo.cloneUrl))
            }
        }
    }

    private func details(_ repo: HostingApi.RemoteRepo, isLocal: Bool) -> String {
        var parts: [String] = []
        if isLocal { parts.append("已在这台电脑上") }
        if repo.isNotebook { parts.append("以前用这个 App 建的笔记本") }
        parts.append(repo.isPrivate ? "仅自己可见" : "所有人可见")
        if let updated = repo.updatedAt { parts.append("\(agoText(updated))更新") }
        if let account, repo.owner.caseInsensitiveCompare(account.login) != .orderedSame { parts.append("属于 \(repo.owner)") }
        return parts.joined(separator: " · ")
    }

    private func start(_ cloneUrl: String) {
        guard let account else { return }
        let name = name, folder = folder(forCloneUrl: cloneUrl)
        onImport { progress in try await notebooks.importNotebook(url: cloneUrl, account: account, name: name, folder: folder, onProgress: progress) }
    }

    private func load() async {
        repos = nil
        loadError = nil
        picked = nil
        guard let account, account.provider != .other else { return }
        do {
            repos = try await notebooks.listRemote(account)
        } catch {
            loadError = error.localizedDescription
        }
    }
}

struct AboutView: View {
    @EnvironmentObject private var updates: AppUpdates

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "book.closed").font(.system(size: 44)).foregroundStyle(.tint)
            Text("记特").font(.title2.weight(.semibold))
            Text("当前版本 \(updates.currentVersion)").foregroundStyle(.secondary)
            Button("检查更新") { updates.checkNow() }
            Link("项目主页", destination: URL(string: "https://github.com/\(AppUpdates.repo)")!)
            Text("笔记只保存在你自己的 Gitee / GitHub 账号里。检查更新时匿名访问 GitHub，不发送任何笔记内容。")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 400)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

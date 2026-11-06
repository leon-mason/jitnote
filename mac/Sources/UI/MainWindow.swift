import AppKit
import SwiftUI

/// What the window opens to: the current notebook, or the first steps when there is none yet.
struct MainView: View {
    @EnvironmentObject private var notebooks: Notebooks
    @EnvironmentObject private var updates: AppUpdates
    @State private var addingAccount = false
    @State private var addingNotebook = false

    var body: some View {
        Group {
            if let notebook = notebooks.state.currentNotebook {
                // Looked at on every draw (cheap), and redrawn when `folderChecks` changes.
                if notebooks.folderChecks >= 0 && NotebookFolders.isMissing(notebooks.dir(notebook)) {
                    MissingFolderView(notebook: notebook)
                        .id("missing-\(notebook.id)")
                } else {
                    NotebookView(notebook: notebook, addingNotebook: $addingNotebook)
                        .id(notebook.id)
                }
            } else if notebooks.state.accounts.isEmpty {
                Welcome { addingAccount = true }
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "books.vertical").font(.system(size: 44)).foregroundStyle(.tint)
                    Text("还没有笔记本").font(.title2)
                    Text("笔记本就像一个文件夹，里面可以放很多篇笔记。\n新建一个，或者用账号里已有的。")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary)
                    Button("添加笔记本") { addingNotebook = true }.controlSize(.large).buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .sheet(isPresented: $addingAccount) { AddAccountView { addingAccount = false } }
        .sheet(isPresented: $addingNotebook) { AddNotebookView { addingNotebook = false } }
        .modifier(UpdatePrompts())
        .task { updates.checkOnLaunch() }
        // A drive may have been plugged back in, or a folder moved, while the app was behind.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            notebooks.recheckFolders()
        }
    }
}

struct Welcome: View {
    let onStart: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "book.closed").font(.system(size: 48)).foregroundStyle(.tint)
            Text("欢迎使用记特").font(.largeTitle.weight(.semibold))
            Text("你的笔记会保存在你自己的 Gitee 或 GitHub 账号里，只有你自己能看到。换电脑、在手机上打开都不会丢。\n\n这个 App 没有服务器，不会收集你的任何数据。")
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("第一步：连接云端账号", action: onStart)
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: 520)
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One notebook in two columns: the file tree | the open note.
struct NotebookView: View {
    let notebook: Notebook
    @Binding var addingNotebook: Bool

    @EnvironmentObject private var notebooks: Notebooks
    #if GN_DEBUG_HOOKS
    @Environment(\.openSettings) private var openSettings
    #endif
    @StateObject private var bridge = EditorBridge()
    /// The file or folder marked in the tree ("" for none); new items go here. Not saved.
    @State private var highlighted = ""
    @State private var selection: String?
    /// Edit or preview for the open note; reset to the default setting whenever another note is opened.
    @State private var viewMode = ViewMode.edit
    /// nil until the first load, so an empty notebook is not announced before the files are read.
    @State private var tree: [NoteIndex.Entry]?
    @State private var refresh = 0
    @State private var prompt: Prompt?
    @State private var deleting: URL?
    @State private var historyPath: String?
    /// The picture covering the note pane, notebook-relative; the open note stays mounted underneath.
    @State private var imagePath: String?
    @State private var toast: Notebooks.SyncMessage?

    /// `newNote` and `newFolder` carry the folder they create in.
    private enum Prompt: Identifiable {
        case newNote(String), newFolder(String), rename(URL)
        var id: String {
            switch self {
            case .newNote(let folder): "note:\(folder)"
            case .newFolder(let folder): "folder:\(folder)"
            case .rename(let url): "rename:\(url.path)"
            }
        }
    }

    private var root: URL { notebooks.dir(notebook) }
    private var syncing: Bool { notebooks.isSyncing(notebook) }
    private var expanded: Set<String> { notebooks.state.expandedFolders[notebook.id] ?? [] }
    /// Where a new note or folder goes: the highlighted folder, or the folder of the highlighted file.
    private var currentFolder: String { FileTree.currentFolder(tree ?? [], highlighted: highlighted) }

    private struct LoadKey: Equatable {
        let sort: NoteSort, showHidden: Bool, refresh: Int, revision: Int, syncing: Bool
    }

    var body: some View {
        NavigationSplitView {
            Sidebar(notebook: notebook, tree: tree ?? [], expanded: expanded, highlighted: $highlighted,
                    onTap: tap,
                    onNewNote: { prompt = .newNote($0) },
                    onNewFolder: { prompt = .newFolder($0) },
                    onHistory: { historyPath = $0 },
                    // Flush when the prompt opens: the sheet and alert are modal, so the open note can't change after.
                    onRename: { path in
                        Task { await bridge.flush() }
                        prompt = .rename(root.appendingPathComponent(path))
                    },
                    onDelete: { path in
                        Task { await bridge.flush() }
                        deleting = root.appendingPathComponent(path)
                    },
                    onSync: sync,
                    addingNotebook: $addingNotebook)
                .navigationSplitViewColumnWidth(min: 220, ideal: 280)
        } detail: {
            detail
        }
        .navigationTitle(titlePath.map { ($0 as NSString).lastPathComponent } ?? notebook.name)
        .navigationSubtitle(titlePath.map { ($0 as NSString).deletingLastPathComponent } ?? "")
        .task(id: LoadKey(sort: notebooks.state.fileSort, showHidden: notebooks.state.showHiddenFiles, refresh: refresh, revision: notebooks.revision, syncing: syncing)) {
            await load()
            await notebooks.refreshUnsynced(notebook)
        }
        .onReceive(NotificationCenter.default.publisher(for: .newNote)) { _ in prompt = .newNote(currentFolder) }
        .onReceive(NotificationCenter.default.publisher(for: .newFolder)) { _ in prompt = .newFolder(currentFolder) }
        .onReceive(NotificationCenter.default.publisher(for: .syncNow)) { _ in sync() }
        .onReceive(NotificationCenter.default.publisher(for: .toggleViewMode)) { _ in
            if let selection, isMarkdown(selection), !syncing, imagePath == nil { toggleViewMode() }
        }
        #if GN_DEBUG_HOOKS
        .onReceive(NotificationCenter.default.publisher(for: .debugCommand)) { note in
            guard let command = note.object as? String else { return }
            if command.hasPrefix("select ") { show(String(command.dropFirst(7))) }
            if command.hasPrefix("folder ") { highlighted = String(command.dropFirst(7)) }
            if command == "sync" { sync() }
            if command == "newnote" { prompt = .newNote(currentFolder) }
            if command == "settings" { openSettings() }
            debug(command)
        }
        #endif
        .onReceive(NotificationCenter.default.publisher(for: .saveNow)) { _ in
            Task {
                await bridge.flush()
                await notebooks.refreshUnsynced(notebook)
            }
        }
        // Lets the update sheet save the open note before it quits the app to install a new version.
        .onAppear {
            let bridge = bridge
            AppModel.shared.saveOpenNote = { [weak bridge] in await bridge?.flush() }
        }
        // Another program (an AI, a terminal) may have changed or committed things while this app was behind.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await notebooks.refreshUnsynced(notebook) }
        }
        .onChange(of: notebooks.syncMessage) { _, message in
            guard let message, message.notebookId == notebook.id else { return }
            toast = message
            Task {
                try? await Task.sleep(for: .seconds(3))
                if toast == message { toast = nil }
            }
        }
        .overlay(alignment: .bottom) {
            if let toast { Toast(text: toast.text, ok: toast.ok).transition(.opacity) }
        }
        .animation(.default, value: toast)
        .sheet(item: $prompt) { prompt in promptSheet(prompt) }
        .sheet(item: Binding(get: { historyPath.map { PathItem(path: $0) } }, set: { historyPath = $0?.path })) { item in
            HistoryView(notebook: notebook, path: item.path) { historyPath = nil }
        }
        .modifier(SyncQuestionSheet())
        .modifier(FolderChanges(folder: root, onChange: externalChange))
        .alert(deleteTitle, isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("删除", role: .destructive) { delete() }
            Button("取消", role: .cancel) {}
        } message: {
            Text(deleting?.hasDirectoryPath == true || isDirectory(deleting)
                ? "文件夹里的所有笔记都会被删除。同步后其他设备上也会删除。\n误删了也不用怕，历史版本里还能找回。"
                : "同步后其他设备上也会删除。\n误删了也不用怕，历史版本里还能找回。")
        }
    }

    /// What the right pane shows. A reference resolves to its target, so an index or a shortcut never
    /// lands on the empty page.
    private var displayedPath: String? {
        guard let selection else { return nil }
        return NoteIndex.resolveReference(at: root.appendingPathComponent(selection), in: root) ?? selection
    }

    private var viewingImage: Bool { imagePath != nil && !syncing }

    /// The file the window title names: the picture being viewed, else the open file. The sidebar already
    /// shows the notebook name, so it is only the fallback when nothing is open (design.md「首页」).
    private var titlePath: String? { viewingImage ? imagePath : displayedPath }

    /// The picture goes over the open file, not in place of it: replacing a note would count as leaving it,
    /// which saves, records a version and loses the scroll position just for looking at a picture.
    private var detail: some View {
        ZStack {
            openFile
                .opacity(viewingImage ? 0 : 1)
                .allowsHitTesting(!viewingImage)
            if viewingImage, let imagePath {
                ImageViewer(file: root.appendingPathComponent(imagePath), revision: refresh, onClose: closeImage)
                    .id(imagePath)
            }
        }
    }

    @ViewBuilder
    private var openFile: some View {
        if syncing {
            Waiting(message: "正在同步，请稍候…")
        } else if let path = displayedPath, FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path),
                  !NoteIndex.isEditable(path) {
            FilePreview(file: root.appendingPathComponent(path))
                .id(path)
                .toolbar {
                    ToolbarItem {
                        if !viewingImage {
                            Button { NSWorkspace.shared.open(root.appendingPathComponent(path)) } label: {
                                Label("用其他应用打开", systemImage: "arrow.up.forward.app")
                            }
                            .help("用其他应用打开")
                        }
                    }
                }
        } else if let path = displayedPath, FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path) {
            NoteDetail(root: root, path: path, readonly: viewMode == .preview, bridge: bridge,
                       onSaved: { Task { await notebooks.refreshUnsynced(notebook) } },
                       onClose: {
                           Task { await notebooks.refreshUnsynced(notebook) }
                           refresh += 1
                       },
                       onOpenImage: { imagePath = $0 })
                .id(path)
                .toolbar {
                    ToolbarItemGroup {
                        if !viewingImage {
                            if isMarkdown(path) {
                                Button(action: toggleViewMode) {
                                    Label(viewMode == .preview ? "编辑" : "预览", systemImage: viewMode == .preview ? "pencil" : "eye")
                                }
                                .help(viewMode == .preview ? "切换到编辑（⌘E）" : "切换到预览（⌘E）")
                            }
                            Button { historyPath = path } label: { Label("历史版本", systemImage: "clock.arrow.circlepath") }
                                .help("历史版本")
                        }
                    }
                }
        } else {
            Text(tree?.isEmpty == true ? "点文件列表右上角的「新建笔记」写第一篇。" : "选一篇笔记")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    #if GN_DEBUG_HOOKS
    /// Debug commands that go through the same handlers as the interface (see DebugHooks.swift).
    private func debug(_ command: String) {
        let words = command.split(separator: " ", maxSplits: 2).map(String.init)
        func entry(_ path: String) -> NoteIndex.Entry? { FileTree.find(tree ?? [], path: path) }
        switch words.first {
        case "tap": if words.count > 1, let found = entry(words[1]) { tap(found) }
        case "mode": if selection.map(isMarkdown) == true { toggleViewMode() }
        case "mknote": if words.count > 1 { NSLog("debug mknote: \(createNote(named: words[1], in: currentFolder) ?? "ok")") }
        case "mkfolder": if words.count > 1 { NSLog("debug mkfolder: \(createFolder(named: words[1], in: currentFolder) ?? "ok")") }
        case "rename": if words.count > 2 { NSLog("debug rename: \(rename(root.appendingPathComponent(words[1]), to: words[2]) ?? "ok")") }
        case "delete": if words.count > 1 { deleting = root.appendingPathComponent(words[1]); delete() }
        case "state" where words.count > 1:
            let title = prompt.map { p -> String in
                switch p {
                case .newNote(let f): f.isEmpty ? "新建笔记" : "在「\(f.components(separatedBy: "/").last!)」里新建笔记"
                case .newFolder(let f): f.isEmpty ? "新建文件夹" : "在「\(f.components(separatedBy: "/").last!)」里新建文件夹"
                case .rename: "重命名"
                }
            } ?? "-"
            let lines = ["highlighted=\(highlighted)", "selection=\(selection ?? "-")", "image=\(imagePath ?? "-")", "mode=\(viewMode.rawValue)",
                         "expanded=\(expanded.sorted().joined(separator: ","))", "prompt=\(title)", "currentFolder=\(currentFolder)",
                         "rows=\(FileTree.visibleRows(tree ?? [], expanded: expanded).map { String(repeating: " ", count: $0.depth) + $0.entry.path }.joined(separator: "|"))"]
            try? lines.joined(separator: "\n").write(toFile: words[1], atomically: true, encoding: .utf8)
        case "cancel": prompt = nil
        case "closeimage": closeImage()
        default: break
        }
    }
    #endif

    private var deleteTitle: String {
        guard let deleting else { return "" }
        let name = isDirectory(deleting) ? deleting.lastPathComponent : deleting.deletingPathExtension().lastPathComponent
        return "删除「\(name)」？"
    }

    private func isDirectory(_ url: URL?) -> Bool {
        guard let url else { return false }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    private func load() async {
        guard !syncing else { return }
        let root = root, sort = notebooks.state.fileSort, showHidden = notebooks.state.showHiddenFiles
        let selectionAtStart = selection
        tree = await Task.detached { NoteIndex.tree(in: root, sort: sort, showHidden: showHidden) }.value
        guard selection == selectionAtStart else { return }
        revealFolderReference(showHidden: showHidden)
    }

    /// Something in the notebook folder changed on disk, made by another program (an AI, a terminal, Finder).
    /// The file is the only truth: the tree follows it, and so does the note that is open.
    private func externalChange(_ paths: [String]) {
        // The folder itself: moved or deleted, so the window may have to turn into the "folder not found" page.
        if paths.contains("") { notebooks.recheckFolders() }
        // A sync writes many files; the screen is rebuilt when it ends.
        guard !syncing else { return }
        let showHidden = notebooks.state.showHiddenFiles
        let shown = displayedPath.map(Self.normalized)
        let open = shown.map { [$0] + FileTree.ancestors($0) } ?? []
        let relevant = paths.map(Self.normalized).filter { path in
            // The open note's own saves and its folder's bookkeeping change nothing in the tree.
            if open.contains(path) { return false }
            // Hidden names (.DS_Store, .obsidian, editors' swap files) are not in the tree unless asked for.
            return showHidden || !path.split(separator: "/").contains { $0.hasPrefix(".") }
        }
        if !relevant.isEmpty { refresh += 1 }
        if let shown, paths.map(Self.normalized).contains(shown) {
            if FileManager.default.fileExists(atPath: root.appendingPathComponent(displayedPath ?? shown).path) {
                Task { await bridge.reloadFromDisk() }
            } else {
                // Deleted or moved away: the pane falls back to its empty state.
                refresh += 1
            }
        }
        Task { await notebooks.refreshUnsynced(notebook) }
    }

    /// The same name can be spelled with composed or decomposed characters; the file system treats them as one.
    private static func normalized(_ path: String) -> String { path.precomposedStringWithCanonicalMapping }

    /// The right pane is blank until a file is open. When the notebook root's references agree on
    /// one file, show that file instead. A later refresh leaves whatever the user already has open.
    private func revealFolderReference(showHidden: Bool) {
        if let path = displayedPath, FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path) { return }
        guard let target = NoteIndex.referenceTarget(inFolder: "", root: root, showHidden: showHidden) else { return }
        show(target)
    }

    /// A row tapped in the tree. A folder opens or closes (closing moves the highlight up to its
    /// parent); a file is highlighted and opened.
    private func tap(_ entry: NoteIndex.Entry) {
        if !entry.isFolder {
            highlighted = entry.path
            open(entry.path)
        } else if expanded.contains(entry.path) {
            notebooks.setExpandedFolders(notebook.id, expanded.subtracting([entry.path]))
            highlighted = FileTree.parent(entry.path)
        } else {
            notebooks.setExpandedFolders(notebook.id, expanded.union([entry.path]))
            highlighted = entry.path
        }
    }

    /// Opens the folders above a new item, so it is visible, and highlights it.
    private func reveal(_ path: String) {
        notebooks.setExpandedFolders(notebook.id, expanded.union(FileTree.ancestors(path)))
        highlighted = path
    }

    /// A file picked in the sidebar: pictures in the viewer over the right pane; notes and text on the right to edit,
    /// anything else (Office, PDF…) on the right in a Quick Look preview. A reference opens its target.
    private func open(_ path: String) {
        let resolved = NoteIndex.resolveReference(at: root.appendingPathComponent(path), in: root) ?? path
        if NoteAssets.isImage(resolved) {
            imagePath = resolved
        } else {
            show(resolved)
        }
    }

    /// Opens [path] on the right. Every change of the open note goes through here, so the mode
    /// starts from the default setting (or [mode]) on each note; reopening the open note keeps it.
    /// A reference opens the file it points at.
    private func show(_ path: String, mode: ViewMode? = nil) {
        // Before the early return: picking the note a picture is covering has to uncover it.
        imagePath = nil
        let resolved = NoteIndex.resolveReference(at: root.appendingPathComponent(path), in: root) ?? path
        if resolved == selection && mode == nil { return }
        selection = resolved
        viewMode = mode ?? notebooks.state.defaultViewMode
    }

    /// Back to what the picture was covering. A picture picked in the tree took the highlight, which returns to the note.
    private func closeImage() {
        if highlighted == imagePath, let selection { highlighted = selection }
        imagePath = nil
    }

    private func isMarkdown(_ path: String) -> Bool {
        ["md", "markdown"].contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }

    private func toggleViewMode() { viewMode = viewMode == .preview ? .edit : .preview }

    private func sync() {
        Task {
            await bridge.flush()
            notebooks.startSync(notebook)
        }
    }

    @ViewBuilder
    private func promptSheet(_ prompt: Prompt) -> some View {
        switch prompt {
        case .newNote(let folder):
            TextPrompt(title: folder.isEmpty ? "新建笔记" : "在「\(folder.components(separatedBy: "/").last!)」里新建笔记",
                       label: "标题", confirm: "创建", onCancel: { self.prompt = nil }) { name in
                createNote(named: name, in: folder)
            }
        case .newFolder(let folder):
            TextPrompt(title: folder.isEmpty ? "新建文件夹" : "在「\(folder.components(separatedBy: "/").last!)」里新建文件夹",
                       label: "文件夹名称", confirm: "创建", onCancel: { self.prompt = nil }) { name in
                createFolder(named: name, in: folder)
            }
        case .rename(let url):
            let wasFolder = isDirectory(url)
            TextPrompt(title: "重命名", label: "新名称",
                       initial: wasFolder ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent,
                       onCancel: { self.prompt = nil }) { name in
                rename(url, to: name)
            }
        }
    }

    /// Creates a note in [folder], then opens it for editing. Returns an error message, or nil.
    private func createNote(named name: String, in folder: String) -> String? {
        // The folder may have gone in the moment before the window noticed; creating a note would make it again.
        if NotebookFolders.isMissing(root) { notebooks.recheckFolders(); return "找不到这个笔记本的文件夹" }
        do {
            let file = try NoteFiles.createNote(in: root.appendingPathComponent(folder), name: name)
            let path = NoteIndex.relativePath(of: file, in: root)
            prompt = nil
            refresh += 1
            reveal(path)
            show(path, mode: .edit)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func createFolder(named name: String, in folder: String) -> String? {
        if NotebookFolders.isMissing(root) { notebooks.recheckFolders(); return "找不到这个笔记本的文件夹" }
        do {
            let created = try NoteFiles.createFolder(in: root.appendingPathComponent(folder), name: name)
            prompt = nil
            refresh += 1
            reveal(NoteIndex.relativePath(of: created, in: root))
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func rename(_ url: URL, to name: String) -> String? {
        do {
            let old = NoteIndex.relativePath(of: url, in: root)
            let renamed = try NoteFiles.rename(url, to: name)
            let new = NoteIndex.relativePath(of: renamed, in: root)
            prompt = nil
            // The tree keeps its open folders and highlight under the new name.
            notebooks.setExpandedFolders(notebook.id, FileTree.renamed(expanded, old: old, new: new))
            highlighted = FileTree.moved(highlighted, old: old, new: new)
            selection = selection.map { FileTree.moved($0, old: old, new: new) }
            imagePath = imagePath.map { FileTree.moved($0, old: old, new: new) }
            Task { await notebooks.refreshUnsynced(notebook) }
            refresh += 1
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func delete() {
        guard let url = deleting else { return }
        deleting = nil
        let path = NoteIndex.relativePath(of: url, in: root)
        if selection == path || selection?.hasPrefix(path + "/") == true { selection = nil }
        if imagePath == path || imagePath?.hasPrefix(path + "/") == true { imagePath = nil }
        notebooks.setExpandedFolders(notebook.id, FileTree.removed(expanded, path: path))
        if highlighted == path || highlighted.hasPrefix(path + "/") { highlighted = FileTree.parent(path) }
        Task {
            // Nothing is committed between syncs, so keep a version of what is about to disappear.
            await notebooks.keepVersion(notebook, paths: [path])
            try? await notebooks.run(notebook) { _ in try FileManager.default.removeItem(at: url) }
            await notebooks.refreshUnsynced(notebook)
            refresh += 1
        }
    }
}

private struct PathItem: Identifiable {
    let path: String
    var id: String { path }
}

private struct NoteDetail: View {
    let root: URL
    let path: String
    let readonly: Bool
    let bridge: EditorBridge
    let onSaved: () -> Void
    let onClose: () -> Void
    let onOpenImage: (String) -> Void
    @State private var content: String?

    private var url: URL { root.appendingPathComponent(path) }

    var body: some View {
        Group {
            if let content {
                if ["md", "markdown"].contains(url.pathExtension.lowercased()) {
                    RichEditor(root: root, path: path, content: content, readonly: readonly, bridge: bridge,
                               onSaved: onSaved, onOpenImage: onOpenImage, onClose: onClose)
                } else {
                    PlainEditor(file: url, initial: content, bridge: bridge, onSaved: onSaved, onClose: onClose)
                }
            } else {
                Waiting(message: "正在打开…")
            }
        }
        .task {
            let url = url
            content = await Task.detached { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }.value
        }
    }
}

/// Left column: notebook switcher, sync status and every file and folder, like Obsidian's file explorer.
private struct Sidebar: View {
    let notebook: Notebook
    let tree: [NoteIndex.Entry]
    let expanded: Set<String>
    /// What is marked: a file or folder path, or "" for nothing.
    @Binding var highlighted: String
    let onTap: (NoteIndex.Entry) -> Void
    let onNewNote: (String) -> Void
    let onNewFolder: (String) -> Void
    let onHistory: (String) -> Void
    let onRename: (String) -> Void
    let onDelete: (String) -> Void
    let onSync: () -> Void
    @Binding var addingNotebook: Bool

    @EnvironmentObject private var notebooks: Notebooks
    @Environment(\.openSettings) private var openSettings

    private static let indent: CGFloat = 14

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The notebook and its sync sit together: what is synced, how far, and the button that does it.
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 8) {
                    notebookMenu
                    Spacer(minLength: 0)
                    syncButton
                }
                SyncStatusLine(notebook: notebook, syncing: notebooks.isSyncing(notebook), unsynced: notebooks.unsynced.contains(notebook.id))
                    .multilineTextAlignment(.trailing)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 12)

            HStack(spacing: 10) {
                Text("文件列表")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button { onNewNote(FileTree.currentFolder(tree, highlighted: highlighted)) } label: {
                    Label("新建笔记", systemImage: "square.and.pencil").labelStyle(.iconOnly)
                }
                .help("新建笔记（⌘N）")
                Button { onNewFolder(FileTree.currentFolder(tree, highlighted: highlighted)) } label: {
                    Label("新建文件夹", systemImage: "folder.badge.plus").labelStyle(.iconOnly)
                }
                .help("新建文件夹（⇧⌘N）")
                Menu {
                    Picker("排序", selection: Binding(get: { notebooks.state.fileSort }, set: { notebooks.setFileSort($0) })) {
                        ForEach(NoteSort.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("排序", systemImage: "arrow.up.arrow.down").labelStyle(.iconOnly)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("排序方式")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .padding(.bottom, 6)

            // Drawn by hand rather than with List or OutlineGroup: List(selection:) says nothing when
            // the selected row is tapped again (a folder could not be closed), and OutlineGroup's
            // open state cannot be controlled from outside.
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(FileTree.visibleRows(tree, expanded: expanded)) { row in
                        self.row(row)
                    }
                }
                .padding(.horizontal, 6)
            }
            .contentShape(Rectangle())
            .onTapGesture { highlighted = "" }
        }
    }

    private var notebookMenu: some View {
        Menu {
            ForEach(notebooks.state.notebooks) { other in
                Button { notebooks.setCurrent(other.id) } label: {
                    if other.id == notebook.id { Label(other.name, systemImage: "checkmark") } else { Text(other.name) }
                }
            }
            Divider()
            Button("添加笔记本…") { addingNotebook = true }
            Button("管理笔记本…") { openSettings() }
            Divider()
            // For pointing an AI tool at the notebook: its folder is a plain Git folder anyone can work in.
            Button("打开文件夹") { NSWorkspace.shared.open(notebooks.dir(notebook)) }
            Button("复制路径") { copyToPasteboard(notebooks.dir(notebook).path) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "books.vertical")
                Text(notebook.name).lineLimit(1).truncationMode(.middle)
                Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            }
            .font(.title3.weight(.semibold))
            .contentShape(Rectangle())
        }
        // A borderless menu button draws its label at a fixed small size and ignores the font above.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .help("切换笔记本")
    }

    @ViewBuilder
    private var syncButton: some View {
        if notebooks.isSyncing(notebook) {
            ProgressView().controlSize(.small).help("正在同步…")
        } else {
            let unsynced = notebooks.unsynced.contains(notebook.id)
            Button(action: onSync) {
                Label("同步", systemImage: unsynced ? "arrow.triangle.2.circlepath.circle.fill" : "arrow.triangle.2.circlepath")
                    .labelStyle(.iconOnly)
                    .font(.title3)
            }
            .buttonStyle(.borderless)
            .help(unsynced ? "有未同步的修改（⌘R）" : "同步（⌘R）")
        }
    }

    private func row(_ row: FileTree.Row) -> some View {
        let entry = row.entry
        return HStack(spacing: 4) {
            // Every folder shows an arrow, empty ones too; files keep the space so names line up.
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(expanded.contains(entry.path) ? 90 : 0))
                .opacity(entry.isFolder ? 1 : 0)
                .frame(width: 12)
            Image(systemName: icon(entry)).frame(width: 18)
            Text(entry.name).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            if entry.isFolder { Text("\(entry.noteCount)").foregroundStyle(.secondary) }
        }
        .padding(.leading, CGFloat(row.depth) * Self.indent + 4)
        .padding(.trailing, 6)
        .padding(.vertical, 4)
        .background(highlighted == entry.path ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { onTap(entry) }
        .accessibilityAddTraits(.isButton)
        .contextMenu { menu(entry) }
    }

    @ViewBuilder
    private func menu(_ entry: NoteIndex.Entry) -> some View {
        if entry.isFolder {
            Button("新建笔记…") { onNewNote(entry.path) }
            Button("新建文件夹…") { onNewFolder(entry.path) }
            Divider()
        }
        if !entry.isFolder && NoteIndex.isEditable(entry.path) {
            Button("历史版本…") { onHistory(entry.path) }
        }
        Button("重命名…") { onRename(entry.path) }
        Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([notebooks.dir(notebook).appendingPathComponent(entry.path)]) }
        Divider()
        Button("删除…", role: .destructive) { onDelete(entry.path) }
    }

    private func icon(_ entry: NoteIndex.Entry) -> String {
        if entry.isFolder { return "folder" }
        if NoteAssets.isImage(entry.path) { return "photo" }
        return NoteIndex.isEditable(entry.path) ? "doc.text" : "doc"
    }
}

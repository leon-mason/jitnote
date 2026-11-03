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
                NotebookView(notebook: notebook, addingNotebook: $addingNotebook)
                    .id(notebook.id)
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
    @State private var conflictCount = 0
    @State private var refresh = 0
    @State private var prompt: Prompt?
    @State private var deleting: URL?
    @State private var historyPath: String?
    @State private var showingConflicts = false
    @State private var image: URL?
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
                    conflictCount: conflictCount,
                    onTap: tap,
                    onConflicts: { showingConflicts = true },
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
                    addingNotebook: $addingNotebook)
                .navigationSplitViewColumnWidth(min: 220, ideal: 280)
        } detail: {
            detail
        }
        .navigationTitle(notebook.name)
        .toolbar {
            ToolbarItemGroup {
                Button { prompt = .newNote(currentFolder) } label: { Label("新建笔记", systemImage: "square.and.pencil") }
                    .help("新建笔记（⌘N）")
                // The sidebar card is gone when the sidebar is collapsed, so the toolbar keeps a way in.
                if conflictCount > 0 {
                    Button { showingConflicts = true } label: { Label("冲突", systemImage: "exclamationmark.triangle") }
                        .help("有 \(conflictCount) 篇笔记在两个地方都改过，点这里查看")
                }
                if syncing {
                    ProgressView().controlSize(.small).help("正在同步…")
                } else {
                    Button(action: sync) {
                        Label("同步", systemImage: notebooks.unsynced.contains(notebook.id) ? "arrow.triangle.2.circlepath.circle.fill" : "arrow.triangle.2.circlepath")
                    }
                    .help(notebooks.unsynced.contains(notebook.id) ? "有未同步的修改（⌘R）" : "同步（⌘R）")
                }
            }
        }
        .task(id: LoadKey(sort: notebooks.state.fileSort, showHidden: notebooks.state.showHiddenFiles, refresh: refresh, revision: notebooks.revision, syncing: syncing)) {
            await load()
            await notebooks.refreshUnsynced(notebook)
        }
        .onReceive(NotificationCenter.default.publisher(for: .newNote)) { _ in prompt = .newNote(currentFolder) }
        .onReceive(NotificationCenter.default.publisher(for: .newFolder)) { _ in prompt = .newFolder(currentFolder) }
        .onReceive(NotificationCenter.default.publisher(for: .syncNow)) { _ in sync() }
        .onReceive(NotificationCenter.default.publisher(for: .toggleViewMode)) { _ in
            if let selection, isMarkdown(selection), !syncing { toggleViewMode() }
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
        .sheet(isPresented: $showingConflicts) {
            ConflictsView(notebook: notebook) {
                showingConflicts = false
                refresh += 1
            }
        }
        .sheet(item: Binding(get: { image.map { PathItem(path: $0.path) } }, set: { image = $0.map { URL(fileURLWithPath: $0.path) } })) { item in
            ImageViewer(file: URL(fileURLWithPath: item.path)) { image = nil }
        }
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

    @ViewBuilder
    private var detail: some View {
        if syncing {
            Waiting(message: "正在同步，请稍候…")
        } else if let path = displayedPath, FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path),
                  !NoteIndex.isEditable(path) {
            FilePreview(file: root.appendingPathComponent(path))
                .id(path)
                .toolbar {
                    ToolbarItem {
                        Button { NSWorkspace.shared.open(root.appendingPathComponent(path)) } label: {
                            Label("用其他应用打开", systemImage: "arrow.up.forward.app")
                        }
                        .help("用其他应用打开")
                    }
                }
        } else if let path = displayedPath, FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path) {
            NoteDetail(root: root, path: path, readonly: viewMode == .preview, bridge: bridge,
                       onSaved: { Task { await notebooks.refreshUnsynced(notebook) } },
                       onClose: {
                           Task { await notebooks.refreshUnsynced(notebook) }
                           refresh += 1
                       },
                       onOpenImage: { image = root.appendingPathComponent($0) })
                .id(path)
                .toolbar {
                    ToolbarItemGroup {
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
        } else {
            Text(tree?.isEmpty == true ? "点工具栏上的「新建笔记」写第一篇。" : "选一篇笔记")
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
            let lines = ["highlighted=\(highlighted)", "selection=\(selection ?? "-")", "mode=\(viewMode.rawValue)",
                         "expanded=\(expanded.sorted().joined(separator: ","))", "prompt=\(title)", "currentFolder=\(currentFolder)",
                         "rows=\(FileTree.visibleRows(tree ?? [], expanded: expanded).map { String(repeating: " ", count: $0.depth) + $0.entry.path }.joined(separator: "|"))"]
            try? lines.joined(separator: "\n").write(toFile: words[1], atomically: true, encoding: .utf8)
        case "cancel": prompt = nil
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
        conflictCount = await notebooks.conflicts(notebook).count
        guard selection == selectionAtStart else { return }
        revealFolderReference(showHidden: showHidden)
    }

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

    /// A file picked in the sidebar: pictures open in the viewer; notes and text on the right to edit,
    /// anything else (Office, PDF…) on the right in a Quick Look preview. A reference opens its target.
    private func open(_ path: String) {
        let resolved = NoteIndex.resolveReference(at: root.appendingPathComponent(path), in: root) ?? path
        if NoteAssets.isImage(resolved) {
            image = root.appendingPathComponent(resolved)
        } else {
            show(resolved)
        }
    }

    /// Opens [path] on the right. Every change of the open note goes through here, so the mode
    /// starts from the default setting (or [mode]) on each note; reopening the open note keeps it.
    /// A reference opens the file it points at.
    private func show(_ path: String, mode: ViewMode? = nil) {
        let resolved = NoteIndex.resolveReference(at: root.appendingPathComponent(path), in: root) ?? path
        if resolved == selection && mode == nil { return }
        selection = resolved
        viewMode = mode ?? notebooks.state.defaultViewMode
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
    let conflictCount: Int
    let onTap: (NoteIndex.Entry) -> Void
    let onConflicts: () -> Void
    let onNewNote: (String) -> Void
    let onNewFolder: (String) -> Void
    let onHistory: (String) -> Void
    let onRename: (String) -> Void
    let onDelete: (String) -> Void
    @Binding var addingNotebook: Bool

    @EnvironmentObject private var notebooks: Notebooks
    @Environment(\.openSettings) private var openSettings

    private static let indent: CGFloat = 14

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Menu {
                ForEach(notebooks.state.notebooks) { other in
                    Button { notebooks.setCurrent(other.id) } label: {
                        if other.id == notebook.id { Label(other.name, systemImage: "checkmark") } else { Text(other.name) }
                    }
                }
                Divider()
                Button("添加笔记本…") { addingNotebook = true }
                Button("管理笔记本…") { openSettings() }
            } label: {
                Label(notebook.name, systemImage: "books.vertical")
                    .font(.headline)
            }
            .menuStyle(.borderlessButton)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .help("切换笔记本")

            VStack(alignment: .leading, spacing: 6) {
                SyncStatusLine(notebook: notebook, syncing: notebooks.isSyncing(notebook), unsynced: notebooks.unsynced.contains(notebook.id))
                if conflictCount > 0 {
                    Button(action: onConflicts) {
                        Label("有 \(conflictCount) 篇笔记在两个地方都改过，已自动保留较新的版本。点这里查看。", systemImage: "info.circle")
                            .multilineTextAlignment(.leading)
                    }
                    .buttonStyle(.plain)
                    .padding(8)
                    .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                }
                HStack {
                    Text("文件列表")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Menu {
                        Picker("排序", selection: Binding(get: { notebooks.state.fileSort }, set: { notebooks.setFileSort($0) })) {
                            ForEach(NoteSort.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Label("排序", systemImage: "arrow.up.arrow.down")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("排序方式")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

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

            Divider()
            HStack {
                Button { onNewFolder(FileTree.currentFolder(tree, highlighted: highlighted)) } label: {
                    Label("新建文件夹", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.borderless)
                Spacer()
            }
            .padding(10)
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

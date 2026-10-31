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
            Text("欢迎使用 Git 笔记本").font(.largeTitle.weight(.semibold))
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

/// One notebook in three columns: folders | notes | the open note.
struct NotebookView: View {
    let notebook: Notebook
    @Binding var addingNotebook: Bool

    @EnvironmentObject private var notebooks: Notebooks
    @StateObject private var bridge = EditorBridge()
    @State private var folder = ""
    @State private var selection: String?
    @State private var notes: [NoteIndex.Note]?
    @State private var tree: [NoteIndex.Entry] = []
    @State private var total = 0
    @State private var conflictCount = 0
    @State private var refresh = 0
    @State private var prompt: Prompt?
    @State private var deleting: URL?
    @State private var historyPath: String?
    @State private var showingConflicts = false
    @State private var image: URL?
    @State private var toast: Notebooks.SyncMessage?

    private enum Prompt: Identifiable {
        case newNote, newFolder, rename(URL)
        var id: String {
            switch self {
            case .newNote: "note"
            case .newFolder: "folder"
            case .rename(let url): url.path
            }
        }
    }

    private var root: URL { notebooks.dir(notebook) }
    private var syncing: Bool { notebooks.isSyncing(notebook) }
    private var here: URL { folder.isEmpty ? root : root.appendingPathComponent(folder) }

    private struct LoadKey: Equatable {
        let folder: String, sort: NoteSort, refresh: Int, revision: Int, syncing: Bool
    }

    var body: some View {
        NavigationSplitView {
            Sidebar(notebook: notebook, tree: tree, total: total, folder: $folder,
                    onOpenFile: open,
                    onNewFolder: { prompt = .newFolder },
                    onHistory: { historyPath = $0 },
                    onRename: { prompt = .rename(root.appendingPathComponent($0)) },
                    onDelete: { deleting = root.appendingPathComponent($0) },
                    addingNotebook: $addingNotebook)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } content: {
            NoteList(notebook: notebook, notes: notes, folder: folder, conflictCount: conflictCount, selection: $selection,
                     onShowAll: { folder = "" },
                     onConflicts: { showingConflicts = true },
                     onHistory: { historyPath = $0.path },
                     onRename: { prompt = .rename($0.url) },
                     onDelete: { deleting = $0.url })
                .navigationSplitViewColumnWidth(min: 260, ideal: 320)
        } detail: {
            detail
        }
        .navigationTitle(notebook.name)
        .toolbar {
            ToolbarItemGroup {
                Button { prompt = .newNote } label: { Label("新建笔记", systemImage: "square.and.pencil") }
                    .help("新建笔记（⌘N）")
                if syncing {
                    ProgressView().controlSize(.small).help("正在同步…")
                } else {
                    Button(action: sync) { Label("同步", systemImage: "arrow.triangle.2.circlepath") }
                        .help("同步（⌘R）")
                }
            }
        }
        .task(id: LoadKey(folder: folder, sort: notebooks.state.noteSort, refresh: refresh, revision: notebooks.revision, syncing: syncing)) {
            await load()
        }
        .onReceive(NotificationCenter.default.publisher(for: .newNote)) { _ in prompt = .newNote }
        .onReceive(NotificationCenter.default.publisher(for: .newFolder)) { _ in prompt = .newFolder }
        .onReceive(NotificationCenter.default.publisher(for: .syncNow)) { _ in sync() }
        #if GN_DEBUG_HOOKS
        .onReceive(NotificationCenter.default.publisher(for: .debugCommand)) { note in
            guard let command = note.object as? String else { return }
            if command.hasPrefix("select ") { selection = String(command.dropFirst(7)) }
            if command.hasPrefix("folder ") { folder = String(command.dropFirst(7)) }
            if command == "sync" { sync() }
            if command == "newnote" { prompt = .newNote }
        }
        #endif
        .onReceive(NotificationCenter.default.publisher(for: .saveNow)) { _ in
            Task {
                await bridge.flush()
                notebooks.commitInBackground(notebook)
            }
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

    @ViewBuilder
    private var detail: some View {
        if syncing {
            Waiting(message: "正在同步，请稍候…")
        } else if let path = selection, FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path) {
            NoteDetail(root: root, path: path, bridge: bridge,
                       onSaved: {},
                       onClose: {
                           notebooks.commitInBackground(notebook)
                           refresh += 1
                       },
                       onOpenImage: { image = root.appendingPathComponent($0) })
                .id(path)
                .toolbar {
                    ToolbarItem {
                        Button { historyPath = path } label: { Label("历史版本", systemImage: "clock.arrow.circlepath") }
                            .help("历史版本")
                    }
                }
        } else {
            Text(notes?.isEmpty == true ? "点工具栏上的「新建笔记」写第一篇。" : "选一篇笔记")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

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
        let root = root, folder = folder, sort = notebooks.state.noteSort
        // A folder that was renamed or deleted elsewhere (e.g. by a sync) falls back to all notes.
        if !folder.isEmpty && !isDirectory(root.appendingPathComponent(folder)) {
            self.folder = ""
            return
        }
        let (shown, entries, all) = await Task.detached {
            let shown = NoteIndex.notes(in: root, sort: sort, folder: folder)
            let all = folder.isEmpty ? shown.count : NoteIndex.notes(in: root, sort: sort).count
            return (shown, NoteIndex.tree(in: root), all)
        }.value
        notes = shown
        tree = entries
        total = all
        conflictCount = await notebooks.conflicts(notebook).count
    }

    /// A file picked in the sidebar: notes and text open on the right, pictures in the viewer,
    /// anything else in the Mac app that handles it.
    private func open(_ path: String) {
        if NoteAssets.isImage(path) {
            image = root.appendingPathComponent(path)
        } else if NoteIndex.isEditable(path) {
            selection = path
        } else {
            NSWorkspace.shared.open(root.appendingPathComponent(path))
        }
    }

    private func sync() {
        Task {
            await bridge.flush()
            notebooks.startSync(notebook)
        }
    }

    @ViewBuilder
    private func promptSheet(_ prompt: Prompt) -> some View {
        switch prompt {
        case .newNote:
            TextPrompt(title: folder.isEmpty ? "新建笔记" : "在「\(folder.components(separatedBy: "/").last!)」里新建笔记",
                       label: "标题", confirm: "创建", onCancel: { self.prompt = nil }) { name in
                do {
                    let file = try NoteFiles.createNote(in: here, name: name)
                    self.prompt = nil
                    refresh += 1
                    selection = NoteIndex.relativePath(of: file, in: root)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }
        case .newFolder:
            TextPrompt(title: folder.isEmpty ? "新建文件夹" : "在「\(folder.components(separatedBy: "/").last!)」里新建文件夹",
                       label: "文件夹名称", confirm: "创建", onCancel: { self.prompt = nil }) { name in
                do {
                    let created = try NoteFiles.createFolder(in: here, name: name)
                    self.prompt = nil
                    folder = NoteIndex.relativePath(of: created, in: root)
                    refresh += 1
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }
        case .rename(let url):
            let wasFolder = isDirectory(url)
            TextPrompt(title: "重命名", label: "新名称",
                       initial: wasFolder ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent,
                       onCancel: { self.prompt = nil }) { name in
                do {
                    let old = NoteIndex.relativePath(of: url, in: root)
                    let renamed = try NoteFiles.rename(url, to: name)
                    let new = NoteIndex.relativePath(of: renamed, in: root)
                    self.prompt = nil
                    // Keep showing the renamed folder (or the folder inside it), and the renamed note.
                    if wasFolder && (folder == old || folder.hasPrefix(old + "/")) { folder = new + folder.dropFirst(old.count) }
                    if selection == old { selection = new }
                    notebooks.commitInBackground(notebook)
                    refresh += 1
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }
        }
    }

    private func delete() {
        guard let url = deleting else { return }
        deleting = nil
        let path = NoteIndex.relativePath(of: url, in: root)
        if selection == path || selection?.hasPrefix(path + "/") == true { selection = nil }
        if folder == path || folder.hasPrefix(path + "/") { folder = "" }
        Task {
            try? await notebooks.run(notebook) { _ in try FileManager.default.removeItem(at: url) }
            await notebooks.commit(notebook)
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
                    RichEditor(root: root, path: path, content: content, bridge: bridge,
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

/// Left column: notebook switcher, "全部笔记" and every file and folder, like Obsidian's file explorer.
private struct Sidebar: View {
    let notebook: Notebook
    let tree: [NoteIndex.Entry]
    let total: Int
    @Binding var folder: String
    let onOpenFile: (String) -> Void
    let onNewFolder: () -> Void
    let onHistory: (String) -> Void
    let onRename: (String) -> Void
    let onDelete: (String) -> Void
    @Binding var addingNotebook: Bool

    @EnvironmentObject private var notebooks: Notebooks
    @Environment(\.openSettings) private var openSettings
    /// What is highlighted: "" for all notes, or a file or folder path.
    @State private var highlighted = ""

    var body: some View {
        VStack(spacing: 0) {
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

            List(selection: Binding(get: { highlighted }, set: { pick($0 ?? "") })) {
                Label { HStack { Text("全部笔记"); Spacer(); Text("\(total)").foregroundStyle(.secondary) } }
                    icon: { Image(systemName: "note.text") }
                    .tag("")
                Section("文件") {
                    OutlineGroup(tree, children: \.children) { entry in
                        row(entry)
                            .tag(entry.path)
                            .contextMenu { menu(entry) }
                    }
                }
            }
            .listStyle(.sidebar)
            .onAppear { highlighted = folder }
            .onChange(of: folder) { _, value in
                if entry(at: highlighted)?.isFolder != false || value.isEmpty { highlighted = value }
            }

            Divider()
            HStack {
                Button(action: onNewFolder) { Label("新建文件夹", systemImage: "folder.badge.plus") }
                    .buttonStyle(.borderless)
                Spacer()
            }
            .padding(10)
        }
    }

    private func row(_ entry: NoteIndex.Entry) -> some View {
        Label {
            HStack {
                Text(entry.name).lineLimit(1).truncationMode(.middle)
                if entry.isFolder {
                    Spacer()
                    Text("\(entry.noteCount)").foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: icon(entry))
        }
    }

    @ViewBuilder
    private func menu(_ entry: NoteIndex.Entry) -> some View {
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

    /// A folder narrows the note list; a file opens.
    private func pick(_ path: String) {
        highlighted = path
        if path.isEmpty || entry(at: path)?.isFolder == true {
            folder = path
        } else {
            onOpenFile(path)
        }
    }

    private func entry(at path: String, in entries: [NoteIndex.Entry]? = nil) -> NoteIndex.Entry? {
        for entry in entries ?? tree {
            if entry.path == path { return entry }
            if path.hasPrefix(entry.path + "/"), let found = self.entry(at: path, in: entry.children ?? []) { return found }
        }
        return nil
    }
}

/// Middle column: every note (or the chosen folder's), with sort order.
private struct NoteList: View {
    let notebook: Notebook
    let notes: [NoteIndex.Note]?
    let folder: String
    let conflictCount: Int
    @Binding var selection: String?
    let onShowAll: () -> Void
    let onConflicts: () -> Void
    let onHistory: (NoteIndex.Note) -> Void
    let onRename: (NoteIndex.Note) -> Void
    let onDelete: (NoteIndex.Note) -> Void

    @EnvironmentObject private var notebooks: Notebooks

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                SyncStatusLine(notebook: notebook, syncing: notebooks.isSyncing(notebook))
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
                    Text("\(folder.isEmpty ? "全部笔记" : folder.components(separatedBy: "/").last!)\(notes.map { " · \($0.count) 篇" } ?? "")")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    if !folder.isEmpty { Button("看全部", action: onShowAll).buttonStyle(.link) }
                    Menu {
                        Picker("排序", selection: Binding(get: { notebooks.state.noteSort }, set: { notebooks.setSort($0) })) {
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

            if let notes, notes.isEmpty {
                VStack(spacing: 8) {
                    Text(folder.isEmpty ? "这里还没有笔记" : "这个文件夹里还没有笔记").font(.headline)
                    Text("点工具栏上的「新建笔记」写第一篇。\n写完会自动保存，点「同步」就会保存到云端。")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(notes ?? [], selection: $selection) { note in
                    NoteRow(note: note, folder: folder)
                        .tag(note.path)
                        .contextMenu {
                            Button("历史版本…") { onHistory(note) }
                            Button("重命名…") { onRename(note) }
                            Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([note.url]) }
                            Divider()
                            Button("删除…", role: .destructive) { onDelete(note) }
                        }
                }
                .listStyle(.inset)
            }
        }
    }
}

private struct NoteRow: View {
    let note: NoteIndex.Note
    let folder: String

    var body: some View {
        // Where the note is, relative to the folder being shown.
        let location = folder.isEmpty ? note.folder : String(note.folder.dropFirst(min(note.folder.count, folder.count + 1)))
        VStack(alignment: .leading, spacing: 3) {
            Text(note.title).font(.headline).lineLimit(1)
            if !note.preview.isEmpty {
                Text(note.preview).foregroundStyle(.secondary).lineLimit(2)
            }
            Text(location.isEmpty ? friendlyTime(note.modified) : "\(location) · \(friendlyTime(note.modified))")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.vertical, 4)
    }
}

import AppKit
import SwiftUI

/// Every saved version of one note; any of them can be viewed and brought back.
struct HistoryView: View {
    let notebook: Notebook
    let path: String
    let onClose: () -> Void

    @EnvironmentObject private var notebooks: Notebooks
    @State private var versions: [Version]?
    @State private var selected: Version?
    @State private var content: String??
    @State private var confirming = false

    private var title: String { NotebookGit.title(path) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("「\(title)」的历史版本").font(.headline)
                Spacer()
                Button("完成", action: onClose).keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            HSplitView {
                Group {
                    if let versions, versions.isEmpty {
                        VStack(spacing: 8) {
                            Text("还没有历史版本").font(.headline)
                            Text("每次写完离开笔记，都会自动留下一个版本。").foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if let versions {
                        List(versions, selection: Binding(get: { selected?.commit }, set: { id in selected = versions.first { $0.commit == id } })) { version in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(friendlyTime(version.time)).font(.headline)
                                Text(version.message).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .tag(version.commit)
                        }
                    } else {
                        Waiting(message: "正在读取…")
                    }
                }
                .frame(minWidth: 220, idealWidth: 260)

                VStack(alignment: .leading, spacing: 0) {
                    if let selected {
                        ScrollView {
                            Group {
                                switch content {
                                case .none: Text("正在读取…").foregroundStyle(.secondary)
                                case .some(.none): Text("这个版本里笔记已被删除").foregroundStyle(.secondary)
                                case .some(.some(let text)): Text(text.isEmpty ? "（空白）" : text).textSelection(.enabled)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                        }
                        Divider()
                        HStack {
                            Text("来自 \(selected.message.components(separatedBy: "\n").first ?? "")").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("恢复这个版本") { confirming = true }
                        }
                        .padding(12)
                        .task(id: selected.commit) {
                            content = .none
                            let data = try? await notebooks.read(notebook, path: path, at: selected.commit)
                            content = .some(data.map { String(decoding: $0, as: UTF8.self) })
                        }
                    } else {
                        Text("点开任意一个版本可以查看内容，也可以恢复成那个版本。")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(minWidth: 360)
            }
        }
        .frame(width: 760, height: 520)
        .task { versions = (try? await notebooks.history(notebook, path: path)) ?? [] }
        .alert("恢复成这个版本？", isPresented: $confirming) {
            Button("恢复") {
                guard let selected else { return }
                Task {
                    try? await notebooks.restore(notebook, path: path, commit: selected.commit)
                    onClose()
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(content == .some(.none)
                ? "恢复这个版本会删除当前的笔记。"
                : "当前内容会被这个版本替换。不用担心，当前内容也会留在历史版本里。")
        }
    }
}

/// The question a sync asks when a note changed both here and elsewhere: which side wins. Nothing has been
/// merged yet; the side that does not win stays in the history.
struct SyncConflictsView: View {
    let pending: Notebooks.PendingSync
    let onCancel: () -> Void
    let onContinue: ([String: Side]) -> Void

    @State private var choices: [String: Side]
    @State private var comparing: PendingConflict?

    init(pending: Notebooks.PendingSync, onCancel: @escaping () -> Void, onContinue: @escaping ([String: Side]) -> Void) {
        self.pending = pending
        self.onCancel = onCancel
        self.onContinue = onContinue
        _choices = State(initialValue: pending.choices)
    }

    private var allChosen: Bool { pending.conflicts.allSatisfy { choices[$0.path] != nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("「\(pending.notebook.name)」有 \(pending.conflicts.count) 篇笔记在两个地方都改过")
                .font(.title3.weight(.semibold))
            Text("请选择每一篇以哪边为准。没选中的那一版不会丢，仍然留在历史版本里。")
                .foregroundStyle(.secondary)
            HStack {
                Button("全部以这台电脑为准") { choose(.local) }
                Button("全部以云端为准") { choose(.remote) }
            }
            List(pending.conflicts) { conflict in
                VStack(alignment: .leading, spacing: 6) {
                    Text(NotebookGit.title(conflict.path)).font(.headline)
                    if let note = deletion(conflict) { Text(note).font(.callout).foregroundStyle(.secondary) }
                    HStack {
                        Picker("以哪边为准", selection: Binding(get: { choices[conflict.path] }, set: { choices[conflict.path] = $0 })) {
                            Text("这台电脑").tag(Side?.some(.local))
                            Text("云端").tag(Side?.some(.remote))
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 220)
                        Button("看看两边") { comparing = conflict }
                    }
                }
                .padding(.vertical, 6)
            }
            HStack {
                Spacer()
                Button("取消同步", action: onCancel).keyboardShortcut(.cancelAction)
                Button("继续同步") { onContinue(choices) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!allChosen)
            }
        }
        .padding(20)
        .frame(width: 640, height: 520)
        .sheet(item: $comparing) { conflict in
            VStack(alignment: .leading, spacing: 12) {
                Text(NotebookGit.title(conflict.path)).font(.headline)
                HStack(alignment: .top, spacing: 12) {
                    side("这台电脑", conflict.local)
                    side("云端", conflict.cloud)
                }
                HStack {
                    Spacer()
                    Button("关闭") { comparing = nil }.keyboardShortcut(.cancelAction)
                }
            }
            .padding(20)
            .frame(width: 760, height: 480)
        }
    }

    private func choose(_ side: Side) {
        for conflict in pending.conflicts { choices[conflict.path] = side }
    }

    private func deletion(_ conflict: PendingConflict) -> String? {
        if conflict.local == nil { return "这台电脑上已经把它删除了，云端改过了。" }
        if conflict.cloud == nil { return "云端已经把它删除了，这台电脑改过了。" }
        return nil
    }

    private func side(_ title: String, _ content: Data?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            ScrollView {
                Text(preview(content))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(8)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
        .frame(maxWidth: .infinity)
    }

    private func preview(_ content: Data?) -> String {
        guard let content else { return "（已删除）" }
        guard let text = String(data: content, encoding: .utf8) else { return "（不是文字，无法预览）" }
        return text.isEmpty ? "（空白）" : text
    }
}

/// Watches the notebook folder while the window is open and reports what other programs change in it.
struct FolderChanges: ViewModifier {
    let folder: URL
    let onChange: ([String]) -> Void
    @State private var watcher: FolderWatcher?

    func body(content: Content) -> some View {
        content
            .task(id: folder) {
                watcher?.stop()
                watcher = FolderWatcher(folder: folder) { paths in MainActor.assumeIsolated { onChange(paths) } }
            }
            .onDisappear {
                watcher?.stop()
                watcher = nil
            }
    }
}

/// Shows the question a sync asks (`SyncConflictsView`) over the window it is attached to.
struct SyncQuestionSheet: ViewModifier {
    @EnvironmentObject private var notebooks: Notebooks

    func body(content: Content) -> some View {
        // Closing the sheet any way but its two buttons would leave the sync half done with no way to resume.
        content.sheet(item: Binding(get: { notebooks.pendingSync }, set: { _ in })) { pending in
            SyncConflictsView(pending: pending, onCancel: { notebooks.cancelPendingSync() }, onContinue: { notebooks.continueSync($0) })
                .interactiveDismissDisabled()
        }
    }
}

/// The update flow over the main window: new version → download → replace the app in Applications.
struct UpdatePrompts: ViewModifier {
    @EnvironmentObject private var updates: AppUpdates

    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(get: { updates.state != .idle }, set: { if !$0 { updates.dismiss() } })) {
            UpdateSheet().environmentObject(updates)
        }
    }
}

private struct UpdateSheet: View {
    @EnvironmentObject private var updates: AppUpdates
    @State private var quitting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch updates.state {
            case .idle:
                EmptyView()
            case .checking:
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text("正在检查更新…")
                }
                buttons { Button("取消") { updates.dismiss() }.keyboardShortcut(.cancelAction) }
            case .upToDate:
                Text("已经是最新版本").font(.headline)
                Text("当前版本 \(updates.currentVersion)").foregroundStyle(.secondary)
                buttons { Button("好") { updates.dismiss() }.keyboardShortcut(.defaultAction) }
            case .available(let release):
                Text("有新版本 \(release.version)").font(.headline)
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if !release.notes.isEmpty { Text(release.notes) }
                        if release.size > 0 {
                            Text("安装包 \(megabytes(release.size))").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 240)
                buttons {
                    Button("以后再说") { updates.dismiss() }.keyboardShortcut(.cancelAction)
                    Button("更新") { updates.download(release) }.keyboardShortcut(.defaultAction)
                }
            case .downloading(let release, let downloaded):
                Text("正在下载新版本…").font(.headline)
                if release.size > 0 {
                    ProgressView(value: Double(downloaded), total: Double(release.size))
                    Text("\(megabytes(downloaded)) / \(megabytes(release.size))").font(.caption).foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
                buttons { Button("取消") { updates.dismiss() }.keyboardShortcut(.cancelAction) }
            case .downloaded(let release, let file):
                Text("新版本 \(release.version) 已下载好").font(.headline)
                Text(release.isDiskImage
                    ? "还差一步：点「退出并安装」，记特会先退出，然后在弹出的窗口里把「记特」拖到「应用程序」，选择「替换」，再重新打开 App。"
                    : "还差一步：点「退出并安装」，记特会先退出，然后在打开的访达窗口里把「记特」拖到「应用程序」文件夹，选择「替换」，再重新打开 App。")
                    .fixedSize(horizontal: false, vertical: true)
                if quitting {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("正在等同步完成，完成后自动退出…").font(.caption).foregroundStyle(.secondary)
                    }
                }
                buttons {
                    Button("以后再说") { updates.dismiss() }.keyboardShortcut(.cancelAction).disabled(quitting)
                    Button("退出并安装") {
                        if release.isDiskImage {
                            NSWorkspace.shared.open(file)
                        } else {
                            NSWorkspace.shared.activateFileViewerSelecting([file])
                            NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications"))
                        }
                        quitForInstall()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(quitting)
                }
            case .failed(let message, let release):
                Text(release == nil ? "检查更新没有成功" : "更新没有成功").font(.headline)
                Text(message)
                buttons {
                    Button("取消") { updates.dismiss() }.keyboardShortcut(.cancelAction)
                    Button("重试") {
                        if let release { updates.download(release) } else { updates.checkNow() }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    /// Finder can't replace an app that is still running, so the old copy has to go before the user drags
    /// the new one in. The open note is saved first, and a running sync is allowed to finish, so quitting
    /// never cuts a commit or merge in half.
    private func quitForInstall() {
        quitting = true
        Task { @MainActor in
            await AppModel.shared.saveOpenNote?()
            while !AppModel.shared.notebooks.syncing.isEmpty {
                try? await Task.sleep(for: .milliseconds(200))
            }
            NSApp.terminate(nil)
        }
    }

    private func buttons<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        HStack {
            Spacer()
            content()
        }
    }

    private func megabytes(_ bytes: Int64) -> String { String(format: "%.1f MB", Double(bytes) / 1024 / 1024) }
}

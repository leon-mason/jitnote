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

/// Notes changed both here and elsewhere: the newer version was kept; this lets people look at the
/// other one, switch to it, or accept what is there.
struct ConflictsView: View {
    let notebook: Notebook
    let onClose: () -> Void

    @EnvironmentObject private var notebooks: Notebooks
    @State private var records: [ConflictRecord]?
    @State private var viewing: ConflictRecord?
    @State private var otherText: String?
    @State private var switching: ConflictRecord?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("两边都改过的笔记").font(.title3.weight(.semibold))
                Spacer()
                Button("完成", action: onClose).keyboardShortcut(.cancelAction)
            }
            Text("这些笔记在这台电脑和别的地方（另一台设备或手机）都被修改过。App 已经自动保留了较新的版本，另一个版本也没有丢，你可以随时换回去。")
                .foregroundStyle(.secondary)
            if let records, records.isEmpty {
                Text("都处理好了，没有需要确认的笔记。").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let records {
                List(records) { record in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(NotebookGit.title(record.path)).font(.headline)
                        Text("现在用的：\(place(record.kept))的版本（\(time(record.keptTime))修改）").font(.callout)
                        Text(record.otherBlob == nil
                            ? "另一个：\(place(other(record.kept)))把它删除了"
                            : "另一个：\(place(other(record.kept)))的版本（\(time(record.otherTime))修改）").font(.callout).foregroundStyle(.secondary)
                        HStack {
                            if record.otherBlob != nil { Button("看看另一个") { show(record) } }
                            Button("换成另一个") { switching = record }
                            Button("就用现在的") {
                                Task {
                                    await notebooks.dismissConflict(notebook, record)
                                    await load()
                                }
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }
            } else {
                Waiting(message: "正在读取…")
            }
        }
        .padding(20)
        .frame(width: 600, height: 480)
        .task { await load() }
        .sheet(item: $viewing) { record in
            VStack(alignment: .leading, spacing: 12) {
                Text("另一个版本：\(NotebookGit.title(record.path))").font(.headline)
                ScrollView {
                    Text(otherText.map { $0.isEmpty ? "（空白）" : $0 } ?? "正在读取…")
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Spacer()
                    Button("关闭") { viewing = nil }.keyboardShortcut(.cancelAction)
                }
            }
            .padding(20)
            .frame(width: 560, height: 420)
        }
        .alert("换成另一个版本？", isPresented: Binding(get: { switching != nil }, set: { if !$0 { switching = nil } })) {
            Button("换成另一个") {
                guard let record = switching else { return }
                Task {
                    try? await notebooks.useOtherVersion(notebook, record)
                    await load()
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(switching?.otherBlob == nil
                ? "另一个版本里这篇笔记已被删除，换过去会删除这篇笔记（历史版本里仍可找回）。"
                : "当前内容会被另一个版本替换，当前内容仍会留在历史版本里。记得之后点同步。")
        }
    }

    private func load() async { records = await notebooks.conflicts(notebook) }

    private func show(_ record: ConflictRecord) {
        otherText = nil
        viewing = record
        guard let blob = record.otherBlob else { return }
        Task {
            let data = try? await notebooks.run(notebook) { try $0.readBlob(blob) }
            otherText = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
        }
    }

    private func place(_ side: Side) -> String { side == .local ? "这台电脑" : "云端" }
    private func other(_ side: Side) -> Side { side == .local ? .remote : .local }
    private func time(_ millis: Int64) -> String { millis > 0 ? friendlyTime(millis) : "未知时间" }
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
            case .downloaded(let release, let app):
                Text("新版本 \(release.version) 已下载好").font(.headline)
                Text("还差一步：在打开的访达窗口里，把「Git 笔记本」拖到「应用程序」文件夹，选择「替换」，然后重新打开 App。")
                    .fixedSize(horizontal: false, vertical: true)
                buttons {
                    Button("以后再说") { updates.dismiss() }.keyboardShortcut(.cancelAction)
                    Button("在访达中显示") {
                        NSWorkspace.shared.activateFileViewerSelecting([app])
                        NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications"))
                    }
                    .keyboardShortcut(.defaultAction)
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

    private func buttons<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        HStack {
            Spacer()
            content()
        }
    }

    private func megabytes(_ bytes: Int64) -> String { String(format: "%.1f MB", Double(bytes) / 1024 / 1024) }
}

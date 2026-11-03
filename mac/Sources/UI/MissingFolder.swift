import AppKit
import SwiftUI

/// What the window shows for a notebook whose folder cannot be found: moved, deleted, or on a drive that is
/// not plugged in. The notebook stays in the list; nothing is made in the old place, and the only ways on are
/// to find the folder again or download the notebook again (design.md, "笔记本文件夹"). There is deliberately
/// no way to pick a new place for it: a notebook's place never changes.
struct MissingFolderView: View {
    let notebook: Notebook

    @EnvironmentObject private var notebooks: Notebooks
    @Environment(\.openSettings) private var openSettings
    @State private var error: String?
    @State private var progress: String?
    @State private var confirmingDownload = false

    private var path: String { notebooks.dir(notebook).path }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Menu {
                ForEach(notebooks.state.notebooks) { other in
                    Button { notebooks.setCurrent(other.id) } label: {
                        if other.id == notebook.id { Label(other.name, systemImage: "checkmark") } else { Text(other.name) }
                    }
                }
                Divider()
                Button("管理笔记本…") { openSettings() }
            } label: {
                Label(notebook.name, systemImage: "books.vertical").font(.headline)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Spacer()
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: "folder.badge.questionmark").font(.system(size: 44)).foregroundStyle(.orange)
                Text("找不到「\(notebook.name)」的文件夹").font(.title2.weight(.semibold))
                Text("它原来放在：").foregroundStyle(.secondary)
                Text(path).textSelection(.enabled)
                Text("可能被移动或删除了，或者放它的硬盘没有插上。云端的笔记没有受影响。")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let progress {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(progress)
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Button("重新检查") { notebooks.recheckFolders() }
                            .help("硬盘重新插上后点这里")
                        Button("重新选择文件夹…", action: choose)
                            .help("文件夹被移到了别处，指给 App 看")
                        Button("重新下载到原位置…") { confirmingDownload = true }
                    }
                    Text("文件夹只是被移走了？选「重新选择文件夹」指向它，还没同步的修改都在里面。\n文件夹已经没了？选「重新下载」，把云端的内容放回原位置（还没同步的修改就没有了）。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let error { Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            Spacer()
        }
        .padding(28)
        .frame(maxWidth: 620, maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity)
        .alert("重新下载「\(notebook.name)」？", isPresented: $confirmingDownload) {
            Button("下载") { download() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会把云端的内容下载到「\(path)」。这个位置现在必须是空的或者不存在。\n这台电脑上没有同步过的修改，如果原来的文件夹找不回来，就没有了。")
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        panel.message = "选这个笔记本原来的文件夹：它被移到了哪里，就选哪里。"
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
        guard panel.runModal() == .OK, let url = panel.url else { return }
        error = nil
        Task {
            do {
                try await notebooks.relocate(notebook, to: url)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func download() {
        error = nil
        progress = "请稍候…"
        Task {
            defer { progress = nil }
            do {
                try await notebooks.redownload(notebook) { progress = $0 }
            } catch {
                self.error = error.localizedDescription.isEmpty ? "出错了，请重试" : error.localizedDescription
            }
        }
    }
}

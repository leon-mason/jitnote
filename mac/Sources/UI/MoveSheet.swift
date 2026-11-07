import SwiftUI

/// The picker behind "移动到…": the notebook root and every folder as an expandable list, to choose where a
/// file or folder goes. It only chooses; checking for a name clash and moving happen in the main window.
struct MoveSheet: View {
    let name: String
    /// Notebook-relative path of what moves.
    let source: String
    let tree: [NoteIndex.Entry]
    let onCancel: () -> Void
    let onMove: (String) -> Void

    /// Opens on the folder the item is in, so the current place is the first thing seen.
    @State private var expanded: Set<String>
    @State private var chosen: String?

    init(name: String, source: String, tree: [NoteIndex.Entry], onCancel: @escaping () -> Void, onMove: @escaping (String) -> Void) {
        self.name = name
        self.source = source
        self.tree = tree
        self.onCancel = onCancel
        self.onMove = onMove
        _expanded = State(initialValue: FileTree.ancestors(source))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("把「\(name)」移动到").font(.headline)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        folderRow(path: "", name: "笔记本根目录", depth: 0, icon: "books.vertical", subfolders: false)
                        ForEach(FileTree.visibleRows(tree, expanded: expanded).filter { $0.entry.isFolder }) { row in
                            folderRow(path: row.entry.path, name: row.entry.name, depth: row.depth + 1, icon: "folder",
                                      subfolders: row.entry.children.contains { $0.isFolder })
                        }
                    }
                    .padding(6)
                }
                .frame(width: 360, height: 280)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))
                .onAppear { proxy.scrollTo(FileTree.parent(source), anchor: .center) }
            }
            HStack {
                Spacer()
                Button("取消", role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
                Button("移动") { if let chosen { onMove(chosen) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(chosen == nil)
            }
        }
        .padding(20)
    }

    private func folderRow(path: String, name: String, depth: Int, icon: String, subfolders: Bool) -> some View {
        // Where it already is, itself and everything inside it are greyed out (FileTree.canMove).
        let allowed = FileTree.canMove(source, into: path)
        return HStack(spacing: 4) {
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(expanded.contains(path) ? 90 : 0))
                .opacity(subfolders ? 1 : 0)
                .frame(width: 12)
                .contentShape(Rectangle())
                .onTapGesture {
                    guard subfolders else { return }
                    if expanded.contains(path) { expanded.remove(path) } else { expanded.insert(path) }
                }
            Image(systemName: icon).frame(width: 18)
            Text(name).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
        }
        .foregroundStyle(allowed ? Color.primary : Color.secondary.opacity(0.6))
        .padding(.leading, CGFloat(max(depth - 1, 0)) * 14 + 4)
        .padding(.trailing, 6)
        .padding(.vertical, 4)
        .background(chosen == path && allowed ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { if allowed { chosen = path } }
        .id(path)
    }
}

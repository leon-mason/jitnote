import Foundation

/// Pure rules of the file tree screen: what rows show, and how paths follow renames and deletes.
/// Same rules as `FileTree.kt` on Android.
enum FileTree {
    struct Row: Identifiable {
        let entry: NoteIndex.Entry
        let depth: Int

        var id: String { entry.path }
    }

    /// The rows to draw: a folder's children only follow it when its path is in [expanded].
    static func visibleRows(_ tree: [NoteIndex.Entry], expanded: Set<String>) -> [Row] {
        var rows: [Row] = []
        func walk(_ entries: [NoteIndex.Entry], depth: Int) {
            for entry in entries {
                rows.append(Row(entry: entry, depth: depth))
                if entry.isFolder && expanded.contains(entry.path) { walk(entry.children, depth: depth + 1) }
            }
        }
        walk(tree, depth: 0)
        return rows
    }

    static func find(_ tree: [NoteIndex.Entry], path: String) -> NoteIndex.Entry? {
        for entry in tree {
            if entry.path == path { return entry }
            if entry.isFolder && path.hasPrefix(entry.path + "/"), let found = find(entry.children, path: path) { return found }
        }
        return nil
    }

    /// The folder containing [path]; "" at the top level.
    static func parent(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    /// Every folder above [path]: "a/b/c.md" gives {"a", "a/b"}.
    static func ancestors(_ path: String) -> Set<String> {
        var result: Set<String> = []
        var folder = parent(path)
        while !folder.isEmpty {
            result.insert(folder)
            folder = parent(folder)
        }
        return result
    }

    /// Where a new note or folder goes: the highlighted folder, or the folder of the highlighted file.
    static func currentFolder(_ tree: [NoteIndex.Entry], highlighted: String) -> String {
        guard let entry = find(tree, path: highlighted) else { return "" }
        return entry.isFolder ? entry.path : parent(entry.path)
    }

    /// [path] after [old] became [new]: only [old] itself and what is inside it change.
    static func moved(_ path: String, old: String, new: String) -> String {
        path == old || path.hasPrefix(old + "/") ? new + path.dropFirst(old.count) : path
    }

    static func renamed(_ expanded: Set<String>, old: String, new: String) -> Set<String> {
        Set(expanded.map { moved($0, old: old, new: new) })
    }

    static func removed(_ expanded: Set<String>, path: String) -> Set<String> {
        expanded.filter { $0 != path && !$0.hasPrefix(path + "/") }
    }
}

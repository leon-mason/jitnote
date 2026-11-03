import Foundation

/// Where a notebook lives on this Mac, and which folders may become one (design.md, "笔记本文件夹").
/// Only a notebook's creation uses this: the place can never be changed afterwards.
enum NotebookFolders {
    /// Where notebooks go unless the user picks another place.
    static var defaultRoot: URL { URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Jitnote", isDirectory: true) }

    /// The default place for a notebook whose cloud repository is called [name]: `~/Jitnote/<name>`, and
    /// `<name> 2`, `<name> 3`… when that is taken, so nothing already there is ever touched.
    static func defaultFolder(named name: String, root: URL = defaultRoot) -> URL {
        let base = folderName(from: name)
        for number in 1...1000 {
            let candidate = root.appendingPathComponent(number == 1 ? base : "\(base) \(number)", isDirectory: true)
            if isEmptyOrMissing(candidate) { return candidate }
        }
        return root.appendingPathComponent("\(base) \(UUID().uuidString.prefix(8))", isDirectory: true)
    }

    /// Whether [folder] sits directly in the default root; such a notebook is the app's to clean up
    /// when it is removed, while a folder picked elsewhere is left alone.
    static func isInDefaultRoot(_ folder: URL, root: URL = defaultRoot) -> Bool {
        canonical(folder.deletingLastPathComponent()) == canonical(root)
    }

    /// Why [folder] cannot become a notebook, or nil when it can: a notebook starts as exactly what the
    /// cloud has, so the folder must be empty (Finder's `.DS_Store` does not count), and it must not
    /// sit inside another notebook, whose tree would then show it as a subfolder.
    static func problem(with folder: URL, otherNotebooks: [URL] = []) -> String? {
        var isFolder: ObjCBool = false
        if FileManager.default.fileExists(atPath: folder.path, isDirectory: &isFolder) {
            if !isFolder.boolValue { return "这个位置是一个文件，不是文件夹。" }
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else {
                return "没有权限使用这个文件夹。"
            }
            if items.contains(where: { $0 != ".DS_Store" }) {
                return "这个文件夹不是空的。请选一个空文件夹，或者在选择窗口里点「新建文件夹」。"
            }
        }
        let path = canonical(folder)
        for other in otherNotebooks.map(canonical) where path == other || path.hasPrefix(other + "/") {
            return "这个文件夹在另一个笔记本里面。"
        }
        return nil
    }

    /// A warning for places that another program keeps in sync (iCloud Drive, Dropbox…). The two syncs
    /// race on the notebook's hidden `.git` folder, and a half-synced one can corrupt its history.
    /// Not an error: the user may know better.
    static func syncWarning(for folder: URL) -> String? {
        let parts = canonical(folder).split(separator: "/").map(String.init)
        let synced = parts.contains { part in
            part == "Mobile Documents" || part == "CloudStorage" || part == "com~apple~CloudDocs" || part == "iCloud Drive"
                || part.hasPrefix("Dropbox") || part.hasPrefix("OneDrive") || part.hasPrefix("Google Drive")
        }
        return synced ? "这个位置会被 iCloud 云盘或网盘同步。它们和笔记本自己的同步会互相干扰，可能弄坏笔记本里的版本记录。建议换一个不会被同步的位置。" : nil
    }

    /// A name that is safe as a folder name: no separators, and not hidden.
    static func folderName(from name: String) -> String {
        var cleaned = name.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        return cleaned.isEmpty ? "笔记本" : cleaned
    }

    private static func isEmptyOrMissing(_ folder: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: folder.path) else { return true }
        return problem(with: folder) == nil
    }

    /// Symlinks resolved, so /var and /private/var (or a shortcut to the folder) compare as the same place.
    private static func canonical(_ url: URL) -> String { url.resolvingSymlinksInPath().standardizedFileURL.path }
}

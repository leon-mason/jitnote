import Foundation

/// The notebook as the main window shows it: every visible file and folder as a tree.
/// Hidden files and folders (.git, .obsidian, ...) are skipped. Same rules as Android.
enum NoteIndex {
    /// A file or folder in the sidebar tree, named in full like Obsidian's file explorer.
    struct Entry: Identifiable, Hashable {
        let path: String
        let name: String
        let isFolder: Bool
        /// Contents of a folder; empty for files.
        let children: [Entry]
        /// Notes in a folder, including its subfolders; 0 for files.
        let noteCount: Int
        let modified: Int64

        var id: String { path }
    }

    static let noteExtensions: Set<String> = ["md", "markdown", "txt"]

    /// Hidden files start with "." (.obsidian, .gitignore) and are only listed when [showHidden] is on.
    /// Git's own .git folder is never listed: changing it by hand can break the notebook.
    static func isHidden(_ name: String, showHidden: Bool) -> Bool {
        name == ".git" || (!showHidden && name.hasPrefix("."))
    }

    /// Every visible file and folder under [root]. Folders come first; within each group the order
    /// follows [sort], except that folders stay sorted by name when sorting by modification time.
    static func tree(in root: URL, sort: NoteSort = .titleAsc, showHidden: Bool = false) -> [Entry] {
        entries(in: root, root: root, sort: sort, showHidden: showHidden)
    }

    private static func entries(in dir: URL, root: URL, sort: NoteSort, showHidden: Bool) -> [Entry] {
        // Minutes, not milliseconds: files written together are listed by name.
        func minute(_ item: (url: URL, isFolder: Bool, modified: Int64)) -> Int64 { item.modified / 60_000 }
        func name(_ item: (url: URL, isFolder: Bool, modified: Int64)) -> String { item.url.lastPathComponent }
        let items = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { !isHidden($0.lastPathComponent, showHidden: showHidden) }
            .map { (url: $0, isFolder: isDirectory($0), modified: modified($0)) }
            .sorted { a, b in
                if a.isFolder != b.isFolder { return a.isFolder }
                if a.isFolder { return sort == .titleDesc ? compareTitles(name(b), name(a)) : compareTitles(name(a), name(b)) }
                switch sort {
                case .modifiedDesc: return minute(a) != minute(b) ? minute(a) > minute(b) : compareTitles(name(a), name(b))
                case .modifiedAsc: return minute(a) != minute(b) ? minute(a) < minute(b) : compareTitles(name(a), name(b))
                case .titleAsc: return compareTitles(name(a), name(b))
                case .titleDesc: return compareTitles(name(b), name(a))
                }
            }
        return items.map { item in
            let children = item.isFolder ? entries(in: item.url, root: root, sort: sort, showHidden: showHidden) : []
            return Entry(
                path: relativePath(of: item.url, in: root),
                name: item.url.lastPathComponent.precomposedStringWithCanonicalMapping,
                isFolder: item.isFolder,
                children: children,
                noteCount: item.isFolder ? countNotes(children) : 0,
                modified: item.modified
            )
        }
    }

    private static func countNotes(_ entries: [Entry]) -> Int {
        entries.reduce(0) { total, entry in
            total + (entry.isFolder ? entry.noteCount : (noteExtensions.contains((entry.name as NSString).pathExtension.lowercased()) ? 1 : 0))
        }
    }

    /// Text files the plain editor can open (same list as Android).
    static let textExtensions: Set<String> = [
        "md", "markdown", "txt", "text", "json", "yml", "yaml", "toml", "csv", "tsv",
        "html", "htm", "css", "js", "ts", "kt", "java", "py", "sh", "xml", "ini", "conf", "log", "org", "rst", "tex",
    ]

    static func isEditable(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return ext.isEmpty || textExtensions.contains(ext)
    }

    /// Chinese by pinyin, Latin letters ignoring case.
    static func compareTitles(_ a: String, _ b: String) -> Bool {
        a.compare(b, options: [.caseInsensitive, .numeric], range: nil, locale: Locale(identifier: "zh_CN")) == .orderedAscending
    }

    /// Only the folders are resolved (/var vs /private/var), never the file itself: a symlinked note
    /// keeps its own name instead of turning into the path of the file it points at.
    static func relativePath(of url: URL, in root: URL) -> String {
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path
        let standardized = url.standardizedFileURL
        let full = standardized.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(standardized.lastPathComponent).path
        guard full.hasPrefix(base + "/") else { return url.lastPathComponent }
        return String(full.dropFirst(base.count + 1)).precomposedStringWithCanonicalMapping
    }

    /// The file a reference opens, relative to [root], or nil if [url] is an ordinary file.
    ///
    /// Notebooks shared with other tools contain two kinds of reference, and neither is the document itself:
    /// an index is a symlink whose text starts with `@` (`CLAUDE.md` → `@AGENTS.md` means the file AGENTS.md,
    /// not a file named `@AGENTS.md`); a shortcut is a symlink or a Finder alias that points straight at a file.
    /// The result stays inside the notebook. A cycle or a target outside the notebook resolves to nothing.
    static func resolveReference(at url: URL, in root: URL) -> String? {
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        var current = url.standardizedFileURL
        var followed = false
        var seen = Set<String>()
        for _ in 0..<8 {
            if !seen.insert(current.path).inserted { return nil }
            if let destination = symbolicTarget(current) {
                followed = true
                guard let next = linkURL(destination, relativeTo: current) else { return nil }
                current = next.standardizedFileURL
                continue
            }
            if let alias = aliasTarget(current) {
                followed = true
                current = alias.standardizedFileURL
                continue
            }
            return followed ? fileInsideNotebook(current, rootPath: rootPath) : nil
        }
        return nil
    }

    /// When the references directly inside [folder] ("" is the notebook root) all point at one file, that file.
    /// Several references that disagree stay closed, so the right pane is not guessed.
    static func referenceTarget(inFolder folder: String, root: URL, showHidden: Bool) -> String? {
        let dir = folder.isEmpty ? root : root.appendingPathComponent(folder)
        guard isDirectory(dir) else { return nil }
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isAliasFileKey]
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: Array(keys))) ?? []
        var targets = Set<String>()
        for item in items where !isHidden(item.lastPathComponent, showHidden: showHidden) {
            let values = try? item.resourceValues(forKeys: keys)
            guard values?.isSymbolicLink == true || values?.isAliasFile == true else { continue }
            if let target = resolveReference(at: item, in: root) { targets.insert(target) }
        }
        return targets.count == 1 ? targets.first : nil
    }

    private static func symbolicTarget(_ url: URL) -> String? {
        guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true else { return nil }
        return try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)
    }

    /// A Finder alias, not a symlink (a symlink also reports itself as an alias file).
    private static func aliasTarget(_ url: URL) -> URL? {
        let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isAliasFileKey])
        guard values?.isSymbolicLink != true, values?.isAliasFile == true else { return nil }
        return try? URL(resolvingAliasFileAt: url, options: [.withoutMounting])
    }

    /// `@AGENTS.md` is an index; `AGENTS.md` or `../AGENTS.md` is a shortcut. Both are relative to the link.
    private static func linkURL(_ destination: String, relativeTo link: URL) -> URL? {
        var raw = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("@") { raw.removeFirst() }
        raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while raw.hasPrefix("./") { raw.removeFirst(2) }
        if raw.isEmpty || raw.contains("://") || raw.contains("\0") { return nil }
        if raw.hasPrefix("/") { return URL(fileURLWithPath: raw) }
        return link.deletingLastPathComponent().appendingPathComponent(raw)
    }

    private static func fileInsideNotebook(_ url: URL, rootPath: String) -> String? {
        let standardized = url.standardizedFileURL
        let full = standardized.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(standardized.lastPathComponent).path
        guard full.hasPrefix(rootPath + "/") else { return nil }
        if full == rootPath + "/.git" || full.hasPrefix(rootPath + "/.git/") { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: full, isDirectory: &isDir), !isDir.boolValue else { return nil }
        return String(full.dropFirst(rootPath.count + 1)).precomposedStringWithCanonicalMapping
    }

    static func modified(_ url: URL) -> Int64 {
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        return Int64(date.timeIntervalSince1970 * 1000)
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }
}

/// Plain file operations inside a notebook's working copy.
enum NoteFiles {
    /// Returns nil if [raw] is not usable as a file name.
    static func cleanName(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
        return name.isEmpty || name == "." || name == ".." || name.hasPrefix(".") ? nil : name
    }

    static func createNote(in dir: URL, name raw: String) throws -> URL {
        guard let name = cleanName(raw) else { throw SyncError(.other, "名称不能为空，也不能以 . 开头") }
        let fileName = name.contains(".") ? name : "\(name).md"
        let file = dir.appendingPathComponent(fileName)
        guard !FileManager.default.fileExists(atPath: file.path) else { throw SyncError(.other, "已存在同名文件") }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let title = fileName.hasSuffix(".md") ? String(fileName.dropLast(3)) : ""
        try (fileName.hasSuffix(".md") ? "# \(title)\n\n" : "").write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    static func createFolder(in dir: URL, name raw: String) throws -> URL {
        guard let name = cleanName(raw) else { throw SyncError(.other, "名称不能为空，也不能以 . 开头") }
        let folder = dir.appendingPathComponent(name, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: folder.path) else { throw SyncError(.other, "已存在同名文件夹") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @discardableResult
    static func rename(_ file: URL, to raw: String) throws -> URL {
        guard var name = cleanName(raw) else { throw SyncError(.other, "名称不能为空，也不能以 . 开头") }
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: file.path, isDirectory: &isDir)
        if !isDir.boolValue && !name.contains(".") && !file.pathExtension.isEmpty { name += ".\(file.pathExtension)" }
        let target = file.deletingLastPathComponent().appendingPathComponent(name)
        if target.standardizedFileURL == file.standardizedFileURL { return file }
        guard !FileManager.default.fileExists(atPath: target.path) else { throw SyncError(.other, "已存在同名文件") }
        try FileManager.default.moveItem(at: file, to: target)
        return target
    }
}

/// Finds the file a note refers to (images for now), the way the editors people come from do:
/// next to the note (Typora), from the notebook root (Obsidian), or by file name anywhere in the
/// notebook (Obsidian's ![[cat.png]]). Never resolves outside the notebook.
final class NoteAssets {
    private let root: URL
    private let rootPath: String

    init(root: URL) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        rootPath = self.root.path
    }

    /// Lower-case file name → notebook-relative paths, built on first use.
    private lazy var byName: [String: [String]] = {
        var map: [String: [String]] = [:]
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) { _, _ in true }
        while let url = walker?.nextObject() as? URL {
            if url.lastPathComponent.hasPrefix(".git") {
                walker?.skipDescendants()
                continue
            }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let path = NoteIndex.relativePath(of: url, in: root)
            map[(path.components(separatedBy: "/").last ?? path).lowercased(), default: []].append(path)
        }
        return map
    }()

    /// Notebook-relative path of the file [reference] points at, seen from a note in [noteFolder]
    /// ("" for the root), or nil if there is no such file. [reference] is already URL-decoded.
    func resolve(noteFolder: String, reference: String) -> String? {
        var path = reference.trimmingCharacters(in: .whitespaces)
        if path.hasPrefix("./") { path.removeFirst(2) }
        if path.isEmpty || path.contains("://") { return nil }
        let candidates = path.hasPrefix("/")
            ? [String(path.drop { $0 == "/" })]
            : [noteFolder.isEmpty ? path : "\(noteFolder)/\(path)", path]
        for candidate in candidates {
            if let found = existing(candidate) { return found }
        }

        // Obsidian style: a bare name or a partial path, matched anywhere; the shortest path wins.
        let wanted = "/" + path.drop { $0 == "/" }.lowercased()
        let name = (path.components(separatedBy: "/").last ?? path).lowercased()
        return byName[name]?
            .filter { ("/" + $0.lowercased()).hasSuffix(wanted) }
            .min { a, b in
                let depthA = a.filter { $0 == "/" }.count, depthB = b.filter { $0 == "/" }.count
                return depthA != depthB ? depthA < depthB : a.count < b.count
            }
    }

    private func existing(_ relativePath: String) -> String? {
        let file = root.appendingPathComponent(relativePath).standardizedFileURL.resolvingSymlinksInPath()
        guard file.path.hasPrefix(rootPath + "/"),
              (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
        else { return nil }
        let path = NoteIndex.relativePath(of: file, in: root)
        return path == ".git" || path.hasPrefix(".git/") ? nil : path
    }

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "bmp", "heic", "heif", "avif", "svg"]

    static func isImage(_ path: String) -> Bool {
        imageExtensions.contains((path as NSString).pathExtension.lowercased())
    }
}

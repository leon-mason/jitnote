import Foundation

/// The notebook as the main window shows it: every note in one flat list, and the folders on their
/// own as a tree. Hidden files and folders (.git, .obsidian, ...) are skipped. Same rules as Android.
enum NoteIndex {
    struct Note: Identifiable, Hashable {
        let url: URL
        /// Relative to the notebook root, e.g. "会议/2026/周会.md".
        let path: String
        /// Folder relative to the notebook root; "" for the root itself.
        let folder: String
        let title: String
        let modified: Int64
        let preview: String

        var id: String { path }
    }

    /// A file or folder in the sidebar tree, named in full like Obsidian's file explorer.
    struct Entry: Identifiable, Hashable {
        let path: String
        let name: String
        let isFolder: Bool
        /// Contents of a folder; nil for files and empty folders, so `OutlineGroup` shows no disclosure arrow.
        let children: [Entry]?
        /// Notes in a folder, including its subfolders; 0 for files.
        let noteCount: Int

        var id: String { path }
    }

    static let noteExtensions: Set<String> = ["md", "markdown", "txt"]

    static func isNote(_ url: URL) -> Bool {
        noteExtensions.contains(url.pathExtension.lowercased()) && !url.hasDirectoryPath && isFile(url)
    }

    /// Hidden files start with "." (.obsidian, .gitignore) and are only listed when [showHidden] is on.
    /// Git's own .git folder is never listed: changing it by hand can break the notebook.
    static func isHidden(_ name: String, showHidden: Bool) -> Bool {
        name == ".git" || (!showHidden && name.hasPrefix("."))
    }

    /// All notes under [folder] (and its subfolders), sorted by [sort].
    static func notes(in root: URL, sort: NoteSort, folder: String = "", showHidden: Bool = false) -> [Note] {
        let start = folder.isEmpty ? root : root.appendingPathComponent(folder)
        let notes = visibleFiles(under: start, showHidden: showHidden).filter(isNote).map { url -> Note in
            let path = relativePath(of: url, in: root)
            let folder = path.contains("/") ? String(path[..<path.lastIndex(of: "/")!]) : ""
            return Note(
                url: url,
                path: path,
                folder: folder,
                title: url.deletingPathExtension().lastPathComponent,
                modified: modified(url),
                preview: preview(readHead(url))
            )
        }
        // Minutes, not milliseconds: a fresh download writes every file at about the same moment,
        // and those should simply be listed by title.
        func minute(_ note: Note) -> Int64 { note.modified / 60_000 }
        return notes.sorted { a, b in
            switch sort {
            case .modifiedDesc: minute(a) != minute(b) ? minute(a) > minute(b) : compareTitles(a.title, b.title)
            case .modifiedAsc: minute(a) != minute(b) ? minute(a) < minute(b) : compareTitles(a.title, b.title)
            case .titleAsc: compareTitles(a.title, b.title)
            case .titleDesc: compareTitles(b.title, a.title)
            }
        }
    }

    /// Every visible file and folder under [root]: folders first, then files, each by name.
    static func tree(in root: URL, showHidden: Bool = false) -> [Entry] { entries(in: root, root: root, showHidden: showHidden) }

    private static func entries(in dir: URL, root: URL, showHidden: Bool) -> [Entry] {
        let items = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { !isHidden($0.lastPathComponent, showHidden: showHidden) }
            .map { (url: $0, isFolder: isDirectory($0)) }
            .sorted { a, b in a.isFolder != b.isFolder ? a.isFolder : compareTitles(a.url.lastPathComponent, b.url.lastPathComponent) }
        return items.map { item in
            let children = item.isFolder ? entries(in: item.url, root: root, showHidden: showHidden) : []
            return Entry(
                path: relativePath(of: item.url, in: root),
                name: item.url.lastPathComponent.precomposedStringWithCanonicalMapping,
                isFolder: item.isFolder,
                children: children.isEmpty ? nil : children,
                noteCount: item.isFolder ? countNotes(children) : 0
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

    static func visibleFiles(under dir: URL, showHidden: Bool = false) -> [URL] {
        guard let walker = FileManager.default.enumerator(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey]
        ) else { return [] }
        var files: [URL] = []
        while let url = walker.nextObject() as? URL {
            if isHidden(url.lastPathComponent, showHidden: showHidden) {
                walker.skipDescendants()
            } else if isFile(url) {
                files.append(url)
            }
        }
        return files
    }

    static func relativePath(of url: URL, in root: URL) -> String {
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path
        let full = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard full.hasPrefix(base + "/") else { return url.lastPathComponent }
        return String(full.dropFirst(base.count + 1)).precomposedStringWithCanonicalMapping
    }

    static func modified(_ url: URL) -> Int64 {
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        return Int64(date.timeIntervalSince1970 * 1000)
    }

    private static func isFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }

    private static func readHead(_ url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 2048)) ?? Data()
        // A cut in the middle of a character would make the whole buffer undecodable; drop the tail bytes.
        for drop in 0...3 where data.count >= drop {
            if let text = String(data: data.dropLast(drop), encoding: .utf8) { return text }
        }
        return ""
    }

    private static let replacements: [(NSRegularExpression, String)] = [
        (#"!\[\[[^\]]*]]"#, ""),                          // ![[embed]]
        (#"!\[([^\]]*)]\([^)]*\)"#, "$1"),                // ![alt](image)
        (#"\[([^\]]*)]\([^)]*\)"#, "$1"),                 // [text](link)
        (#"\[\[(?:[^\]|]*\|)?([^\]]*)]]"#, "$1"),         // [[link|alias]]
        (#"\*\*|__|~~|==|`"#, ""),                        // emphasis markers
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    private static let linePrefix = try! NSRegularExpression(pattern: #"^\s*(?:>\s*)*(?:#{1,6}\s+|[-*+]\s+|\d+[.)]\s+)?(?:\[[ xX]]\s+)?"#)

    /// The first bit of body text for the note list: no front matter, title line, or Markdown markup.
    static func preview(_ markdown: String, maxLength: Int = 100) -> String {
        var lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---" {
            if let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
                lines = Array(lines[(end + 1)...])
            } else {
                lines = []
            }
        }
        lines = Array(lines.drop { $0.trimmingCharacters(in: .whitespaces).isEmpty })
        if lines.first?.drop(while: { $0 == " " }).hasPrefix("# ") == true { lines.removeFirst() }
        let text = lines.map { line -> String in
            var cleaned = linePrefix.stringByReplacingMatches(in: line, range: NSRange(line.startIndex..., in: line), withTemplate: "")
            for (regex, template) in replacements {
                cleaned = regex.stringByReplacingMatches(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned), withTemplate: template)
            }
            return cleaned.trimmingCharacters(in: .whitespaces)
        }
        .filter { !$0.isEmpty }
        .joined(separator: " ")
        return String(text.prefix(maxLength))
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

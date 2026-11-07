import Foundation

/// Before a file or folder is moved, finds the notes whose images would no longer be found
/// (design.md「首页」, decision J-13). Reads only; the notes themselves are never rewritten.
///
/// It judges by standard Markdown paths (relative to the note, or "/" from the notebook root) and
/// ignores `NoteAssets`' look-up by file name: the notebook is also opened in Typora, GitHub and
/// other tools, which do not have that fallback. A reference counts only if it pointed at an
/// existing file before the move and points at nothing after it, so moving a folder together with
/// the images its notes use reports nothing.
enum BrokenImageCheck {
    // ![alt](path "title") and ![alt](<path with spaces>); one level of parentheses is allowed inside a bare path.
    private static let imageReference = try! NSRegularExpression(
        pattern: #"!\[[^\]\n]*\]\(\s*(?:<([^>\n]*)>|((?:[^\s()]|\([^\s()]*\))*))"#)
    private static let scheme = try! NSRegularExpression(pattern: "^[a-zA-Z][a-zA-Z0-9+.-]*:")

    /// Notebook-relative paths of the notes that would lose an image if [source] (a file or folder,
    /// notebook-relative) were moved into [targetFolder] ("" for the root), sorted.
    static func notes(root: URL, moving source: String, to targetFolder: String) -> [String] {
        let name = source.split(separator: "/").last.map(String.init) ?? source
        let target = targetFolder.isEmpty ? name : "\(targetFolder)/\(name)"
        if target == source || target.hasPrefix(source + "/") { return [] }
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        var files: [String] = []
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) { _, _ in true }
        while let url = walker?.nextObject() as? URL {
            if url.lastPathComponent.hasPrefix(".git") {
                walker?.skipDescendants()
                continue
            }
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                files.append(NoteIndex.relativePath(of: url, in: root))
            }
        }
        let before = Set(files)
        let after = Set(files.map { moved($0, source, target) })
        return files.filter(isNote).filter { note in
            guard let data = try? Data(contentsOf: root.appendingPathComponent(note)) else { return false }
            let newNote = moved(note, source, target)
            return references(in: String(decoding: data, as: UTF8.self)).contains { reference in
                resolve(note, reference, in: before) != nil && resolve(newNote, reference, in: after) == nil
            }
        }.sorted()
    }

    private static func isNote(_ path: String) -> Bool {
        let lower = path.lowercased()
        return lower.hasSuffix(".md") || lower.hasSuffix(".markdown")
    }

    private static func moved(_ path: String, _ source: String, _ target: String) -> String {
        path == source || path.hasPrefix(source + "/") ? target + path.dropFirst(source.count) : path
    }

    /// Image paths written in [text], already without ?query / #anchor and URL-decoded; web addresses are left out.
    private static func references(in text: String) -> [String] {
        let visible = outsideCodeBlocks(text)
        let whole = NSRange(visible.startIndex..., in: visible)
        return imageReference.matches(in: visible, range: whole).compactMap { match in
            var raw = ""
            for group in 1...2 where match.range(at: group).location != NSNotFound {
                raw = (visible as NSString).substring(with: match.range(at: group))
                break
            }
            raw = String(raw.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0])
            raw = String(raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0])
            let path = raw.removingPercentEncoding ?? raw
            let range = NSRange(path.startIndex..., in: path)
            if path.isEmpty || path.hasPrefix("//") || scheme.firstMatch(in: path, range: range) != nil { return nil }
            return path
        }
    }

    /// An image inside a fenced code block is sample text, not an image.
    private static func outsideCodeBlocks(_ text: String) -> String {
        var fence: String?
        var kept: [Substring] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.drop { $0 == " " }
            let marker = trimmed.hasPrefix("```") ? "```" : trimmed.hasPrefix("~~~") ? "~~~" : nil
            if fence == nil {
                if let marker { fence = marker } else { kept.append(line) }
            } else if marker == fence {
                fence = nil
            }
        }
        return kept.joined(separator: "\n")
    }

    /// The notebook-relative file [reference] points at from [note], or nil when there is none.
    private static func resolve(_ note: String, _ reference: String, in files: Set<String>) -> String? {
        let folder = note.split(separator: "/", omittingEmptySubsequences: false).dropLast().joined(separator: "/")
        let joined = reference.hasPrefix("/") || folder.isEmpty ? reference : "\(folder)/\(reference)"
        var parts: [Substring] = []
        for part in joined.split(separator: "/", omittingEmptySubsequences: false) {
            switch part {
            case "", ".": break
            case "..": if parts.isEmpty { return nil } else { parts.removeLast() }
            default: parts.append(part)
            }
        }
        let path = parts.joined(separator: "/")
        return files.contains(path) ? path : nil
    }
}

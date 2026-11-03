import Foundation

/// Writes a note back only after a real edit, and only when the text changed — so opening a note,
/// reading it and leaving never modifies the file (same rule as Android's NoteSaver).
///
/// The file is the only truth (design.md, "同步规则"): another program may change it while it is open.
/// `changedOnDisk` and `adopt` let the editor follow such a change instead of overwriting it.
final class NoteSaver {
    private let file: URL
    private var saved: String
    private var edited = false

    init(file: URL, loaded: String) {
        self.file = file
        saved = loaded
    }

    func markEdited() { edited = true }

    @discardableResult
    func save(_ text: String?) -> Bool {
        guard edited, let text, text != saved else { return false }
        // The note is gone: another program deleted or moved it, or this app just did. Writing would bring
        // it back, as a file nobody asked for.
        guard FileManager.default.fileExists(atPath: file.path) else { return false }
        try? text.write(to: file, atomically: true, encoding: .utf8)
        saved = text
        return true
    }

    /// True when the file holds something other than what this saver last read or wrote, i.e. another
    /// program changed it. This app's own saves are told apart by content: the file then equals `saved`.
    func changedOnDisk(_ disk: String) -> Bool { disk != saved }

    /// Takes the file's current text as the new starting point. That is not an edit, so nothing is written back.
    func adopt(_ disk: String) {
        saved = disk
        edited = false
    }
}

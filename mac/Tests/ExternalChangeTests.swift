import Foundation

/// A note open in the editor is not the app's alone: an AI or a terminal may change files at any time.
enum NoteSaverTests {
    static func file(_ root: URL, _ text: String) throws -> URL {
        let file = root.appendingPathComponent("note.md")
        try text.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    static let all: [TestCase] = [
        TestCase("anUneditedNoteIsNeverWritten") { root in
            let url = try file(root, "# 原文\r\n  odd   spacing")
            let before = try Data(contentsOf: url)
            let saver = NoteSaver(file: url, loaded: "# 原文\r\n  odd   spacing")

            // The editor hands back its own serialization, which differs byte for byte; without an edit it is ignored.
            try expect(!saver.save("# 原文\n\nodd spacing\n"))
            try expectEqual(try Data(contentsOf: url), before)
        },

        TestCase("anEditedNoteIsWrittenOnceAndOnlyWhenItChanged") { root in
            let url = try file(root, "v1")
            let saver = NoteSaver(file: url, loaded: "v1")
            saver.markEdited()

            try expect(saver.save("v2"))
            try expectEqual(try String(contentsOf: url, encoding: .utf8), "v2")
            try expect(!saver.save("v2"), "the same text is not written again")
        },

        TestCase("ownSavesAreNotMistakenForOtherPrograms") { root in
            let url = try file(root, "v1")
            let saver = NoteSaver(file: url, loaded: "v1")
            saver.markEdited()
            saver.save("v2")

            // The watcher reports our own write too; the file then holds exactly what was saved.
            try expect(!saver.changedOnDisk(try String(contentsOf: url, encoding: .utf8)))
        },

        TestCase("aChangeByAnotherProgramIsFollowedWithoutWritingBack") { root in
            let url = try file(root, "v1")
            let saver = NoteSaver(file: url, loaded: "v1")
            saver.markEdited()
            try "written by an AI".write(to: url, atomically: true, encoding: .utf8)

            let disk = try String(contentsOf: url, encoding: .utf8)
            try expect(saver.changedOnDisk(disk))
            saver.adopt(disk)

            try expect(!saver.changedOnDisk(disk))
            // Adopting is not an edit: the text the editor now shows is the file's, so there is nothing to write.
            try expect(!saver.save("written by an AI"))
            try expect(!saver.save("something the old edit left behind"))
            try expectEqual(try String(contentsOf: url, encoding: .utf8), "written by an AI")
        },

        TestCase("aNoteDeletedBehindTheEditorIsNotBroughtBack") { root in
            let url = try file(root, "v1")
            let saver = NoteSaver(file: url, loaded: "v1")
            saver.markEdited()
            try FileManager.default.removeItem(at: url)

            try expect(!saver.save("typed just before it vanished"))
            try expect(!FileManager.default.fileExists(atPath: url.path))
        },
    ]
}

enum FolderWatcherTests {
    /// Runs [action] and collects what the watcher reports until [until] is satisfied (or 5 seconds pass).
    static func reports(in folder: URL, until done: @escaping ([String]) -> Bool, after action: () throws -> Void) throws -> [String] {
        let queue = DispatchQueue(label: "watcher-test")
        let lock = NSLock()
        var seen: [String] = []
        let signal = DispatchSemaphore(value: 0)
        guard let watcher = FolderWatcher(folder: folder, latency: 0.1, queue: queue, onChange: { paths in
            lock.lock()
            seen += paths
            let finished = done(seen)
            lock.unlock()
            if finished { signal.signal() }
        }) else { throw TestFailure(description: "the watcher did not start") }
        defer { watcher.stop() }
        // Let the stream settle, so the first change is not lost to its start-up.
        Thread.sleep(forTimeInterval: 0.3)
        try action()
        _ = signal.wait(timeout: .now() + 5)
        // A moment more, to catch anything that should not have been reported.
        Thread.sleep(forTimeInterval: 0.4)
        lock.lock()
        defer { lock.unlock() }
        return seen
    }

    static let all: [TestCase] = [
        TestCase("reportsFilesCreatedChangedAndRemovedByOthers") { root in
            let seen = try reports(in: root, until: { $0.contains("sub/new.md") && $0.contains("old.md") }) {
                try FileManager.default.createDirectory(at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
                try "x".write(to: root.appendingPathComponent("sub/new.md"), atomically: true, encoding: .utf8)
                try "y".write(to: root.appendingPathComponent("old.md"), atomically: true, encoding: .utf8)
            }
            try expect(seen.contains("sub/new.md"), "\(seen)")
            try expect(seen.contains("old.md"), "\(seen)")

            let removed = try reports(in: root, until: { $0.contains("old.md") }) {
                try FileManager.default.removeItem(at: root.appendingPathComponent("old.md"))
            }
            try expect(removed.contains("old.md"), "\(removed)")
        },

        TestCase("reportsARenameAsBothNames") { root in
            try "x".write(to: root.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
            let seen = try reports(in: root, until: { $0.contains("a.md") && $0.contains("b.md") }) {
                try FileManager.default.moveItem(at: root.appendingPathComponent("a.md"), to: root.appendingPathComponent("b.md"))
            }
            try expect(seen.contains("a.md") && seen.contains("b.md"), "\(seen)")
        },

        TestCase("reportsTheFolderItselfWhenItIsMovedAway") { root in
            let watched = root.appendingPathComponent("watched")
            try FileManager.default.createDirectory(at: watched, withIntermediateDirectories: true)
            let seen = try reports(in: watched, until: { $0.contains("") }) {
                try FileManager.default.moveItem(at: watched, to: root.appendingPathComponent("elsewhere"))
            }
            // "" stands for the folder itself: the window checks whether the notebook is still there.
            try expect(seen.contains(""), "\(seen)")
        },

        TestCase("doesNotReportTheTemporaryFileOfAnAtomicWrite") { root in
            // How the editor saves a note: the temporary name would otherwise look like a new file on every save.
            let seen = try reports(in: root, until: { $0.contains("note.md") }) {
                try "v1".write(to: root.appendingPathComponent("note.md"), atomically: true, encoding: .utf8)
            }
            try expect(seen.contains("note.md"), "\(seen)")
            try expect(!seen.contains { $0.contains(".sb-") }, "\(seen)")
        },

        TestCase("leavesOutWhatHappensInsideTheGitFolder") { root in
            try FileManager.default.createDirectory(at: root.appendingPathComponent(".git/objects"), withIntermediateDirectories: true)
            let seen = try reports(in: root, until: { $0.contains("real.md") }) {
                try "x".write(to: root.appendingPathComponent(".git/objects/abc"), atomically: true, encoding: .utf8)
                try "x".write(to: root.appendingPathComponent(".git/index.lock"), atomically: true, encoding: .utf8)
                try "x".write(to: root.appendingPathComponent("real.md"), atomically: true, encoding: .utf8)
            }
            try expect(seen.contains("real.md"), "\(seen)")
            try expect(!seen.contains { $0 == ".git" || $0.hasPrefix(".git/") }, "\(seen)")
        },
    ]
}

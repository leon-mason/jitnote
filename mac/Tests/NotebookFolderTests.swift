import Foundation

/// Where notebooks live and which folders may become one (design.md, "笔记本文件夹").
enum NotebookFolderTests {
    static func make(_ url: URL, files: [String] = []) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for file in files { try "x".write(to: url.appendingPathComponent(file), atomically: true, encoding: .utf8) }
    }

    static let all: [TestCase] = [
        TestCase("theDefaultPlaceIsNamedAfterTheRepository") { root in
            let folder = NotebookFolders.defaultFolder(named: "my-notes", root: root)
            try expectEqual(folder.lastPathComponent, "my-notes")
            try expectEqual(folder.deletingLastPathComponent().path, root.path)
            try expect(!FileManager.default.fileExists(atPath: folder.path))
        },

        TestCase("aTakenDefaultPlaceGetsANumberAndNothingThereIsTouched") { root in
            try make(root.appendingPathComponent("my-notes"), files: ["a.md"])
            try make(root.appendingPathComponent("my-notes 2"), files: ["b.md"])
            try make(root.appendingPathComponent("my-notes 3"))

            // An empty folder is free to use, which is why the number stops here.
            try expectEqual(NotebookFolders.defaultFolder(named: "my-notes", root: root).lastPathComponent, "my-notes 3")
        },

        TestCase("anEmptyOrMissingFolderMayBecomeANotebook") { root in
            try expect(NotebookFolders.problem(with: root.appendingPathComponent("missing")) == nil)
            let empty = root.appendingPathComponent("empty")
            try make(empty)
            try expect(NotebookFolders.problem(with: empty) == nil)
            // Finder leaves this behind in any folder it has shown.
            try make(empty, files: [".DS_Store"])
            try expect(NotebookFolders.problem(with: empty) == nil)
        },

        TestCase("aFolderWithAnythingInItIsRefusedWithAReason") { root in
            let folder = root.appendingPathComponent("busy")
            try make(folder, files: ["a.md"])
            try expect(NotebookFolders.problem(with: folder)?.contains("不是空的") == true)

            let hidden = root.appendingPathComponent("hidden")
            try make(hidden, files: [".git"])
            try expect(NotebookFolders.problem(with: hidden) != nil, "a hidden file is still a file")

            try expect(NotebookFolders.problem(with: folder.appendingPathComponent("a.md"))?.contains("文件") == true)
        },

        TestCase("aFolderInsideAnotherNotebookIsRefused") { root in
            let notebook = root.appendingPathComponent("notebook")
            try make(notebook.appendingPathComponent("sub"), files: ["../note.md"])

            let inside = notebook.appendingPathComponent("sub")
            try expect(NotebookFolders.problem(with: inside, otherNotebooks: [notebook])?.contains("另一个笔记本") == true)
            let beside = root.appendingPathComponent("notebook 2")
            try make(beside)
            try expect(NotebookFolders.problem(with: beside, otherNotebooks: [notebook]) == nil)
        },

        TestCase("onlyFoldersDirectlyInTheDefaultRootCountAsTheDefaultPlace") { root in
            try expect(NotebookFolders.isInDefaultRoot(root.appendingPathComponent("x"), root: root))
            try expect(!NotebookFolders.isInDefaultRoot(root.appendingPathComponent("a/x"), root: root))
            try expect(!NotebookFolders.isInDefaultRoot(root.deletingLastPathComponent().appendingPathComponent("elsewhere"), root: root))
        },

        TestCase("warnsAboutPlacesAnotherProgramKeepsInSync") { _ in
            let home = URL(fileURLWithPath: "/Users/someone")
            for path in [
                "Library/Mobile Documents/com~apple~CloudDocs/notes",
                "Library/CloudStorage/Dropbox/notes",
                "Dropbox/notes",
                "OneDrive - Company/notes",
                "Google Drive/notes",
            ] {
                try expect(NotebookFolders.syncWarning(for: home.appendingPathComponent(path)) != nil, path)
            }
            for path in ["Jitnote/notes", "Documents/notes", "Projects/dropbox-clone"] {
                try expect(NotebookFolders.syncWarning(for: home.appendingPathComponent(path)) == nil, path)
            }
        },

        TestCase("folderNamesAreSafeToUse") { _ in
            try expectEqual(NotebookFolders.folderName(from: "a/b:c"), "a-b-c")
            try expectEqual(NotebookFolders.folderName(from: ".hidden"), "hidden")
            try expectEqual(NotebookFolders.folderName(from: "  "), "笔记本")
        },

        TestCase("notebooksSavedByEarlierVersionsStillLoadAndAreRemovedWithTheirFolder") { _ in
            let old = """
            {"id":"n1","name":"读书","accountId":"a","remoteUrl":"https://x/y.git","dir":"n1","createdAt":5,"lastSyncAt":9}
            """
            let notebook = try JSONDecoder().decode(Notebook.self, from: Data(old.utf8))
            try expectEqual(notebook.folderPath, nil)
            try expectEqual(notebook.folderChosen, false)
            try expectEqual(notebook.lastSyncAt, 9)

            var chosen = notebook
            chosen.folderPath = "/Users/someone/Notes"
            chosen.folderChosen = true
            let again = try JSONDecoder().decode(Notebook.self, from: try JSONEncoder().encode(chosen))
            try expectEqual(again, chosen)
        },

        TestCase("aDownloadCreatesTheFoldersAboveThePlaceItGoesInto") { root in
            // The default place is ~/Jitnote/<name>, and ~/Jitnote does not exist the first time.
            let cloud = try NotebookGitTests.Cloud(root)
            let place = root.appendingPathComponent("not/yet/there/notes")
            let notebook = try NotebookGit.clone(url: cloud.url, into: place, credentials: nil)
            try expectEqual(notebook.workTree.path, place.path)
            try expect(FileManager.default.fileExists(atPath: place.appendingPathComponent(".git").path))
        },

        TestCase("aFailedDownloadLeavesTheFolderTheUserChose") { root in
            let chosen = root.appendingPathComponent("chosen")
            try make(chosen)
            do {
                try NotebookGit.clone(url: root.appendingPathComponent("no-such-repo.git").path, into: chosen, credentials: nil)
                throw TestFailure(description: "the download should have failed")
            } catch is TestFailure {
                throw TestFailure(description: "the download should have failed")
            } catch {}
            try expect(FileManager.default.fileExists(atPath: chosen.path), "the user's folder must stay")
            try expectEqual(try FileManager.default.contentsOfDirectory(atPath: chosen.path), [])

            // A folder the download made itself is cleaned up.
            let made = root.appendingPathComponent("made-by-download")
            _ = try? NotebookGit.clone(url: root.appendingPathComponent("no-such-repo.git").path, into: made, credentials: nil)
            try expect(!FileManager.default.fileExists(atPath: made.path))
        },
    ]
}

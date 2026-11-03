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

        TestCase("aFolderIsMissingWhenItIsGoneOrNoLongerANotebook") { root in
            try expect(NotebookFolders.isMissing(root.appendingPathComponent("never-there")))
            let empty = root.appendingPathComponent("empty")
            try make(empty)
            try expect(NotebookFolders.isMissing(empty), "a folder that is back but empty is not the notebook")

            let cloud = try NotebookGitTests.Cloud(root)
            let notebook = try cloud.device("notebook")
            try expect(!NotebookFolders.isMissing(notebook.workTree))
            try FileManager.default.moveItem(at: notebook.workTree, to: root.appendingPathComponent("moved"))
            try expect(NotebookFolders.isMissing(notebook.workTree))
        },

        TestCase("aNotebookIsFoundAgainOnlyInItsOwnFolder") { root in
            let cloud = try NotebookGitTests.Cloud(root)
            let moved = try cloud.device("moved")
            let other = try NotebookGit.clone(url: cloud.url, into: root.appendingPathComponent("taken"), credentials: nil)
            try expectEqual(try moved.originUrl(), cloud.url)

            // Same repository, spelled a little differently.
            try expect(NotebookFolders.relocationProblem(
                folder: moved.workTree, originUrl: try moved.originUrl(), expectedRemote: cloud.url.uppercased() + "/", otherNotebooks: []) == nil)
            // Another repository.
            try expect(NotebookFolders.relocationProblem(
                folder: moved.workTree, originUrl: try moved.originUrl(), expectedRemote: "https://example.com/else.git", otherNotebooks: [])?.contains("另一个笔记本") == true)
            // A folder with nothing to say where it came from.
            try expect(NotebookFolders.relocationProblem(
                folder: moved.workTree, originUrl: nil, expectedRemote: cloud.url, otherNotebooks: [])?.contains("另一个笔记本") == true)
            // Not a notebook at all.
            let plain = root.appendingPathComponent("plain")
            try make(plain, files: ["a.md"])
            try expect(NotebookFolders.relocationProblem(
                folder: plain, originUrl: nil, expectedRemote: cloud.url, otherNotebooks: [])?.contains("没有笔记本") == true)
            // Already another notebook's folder here.
            try expect(NotebookFolders.relocationProblem(
                folder: other.workTree, originUrl: try other.originUrl(), expectedRemote: cloud.url, otherNotebooks: [other.workTree])?.contains("已经是另一个笔记本在用") == true)
        },

        TestCase("aNotebookIsNotDownloadedAgainIntoAPlaceThatIsGoneOrBusy") { root in
            let drive = root.appendingPathComponent("Volumes/unplugged")
            let target = drive.appendingPathComponent("notes")

            // The drive is not there: nothing may be made at its mount point.
            try expect(NotebookFolders.redownloadProblem(target, mayCreateParents: false)?.contains("外置硬盘") == true)
            // The app's own places are made again when needed.
            try expect(NotebookFolders.redownloadProblem(target, mayCreateParents: true) == nil)
            // The drive is back and the old folder is gone.
            try make(drive)
            try expect(NotebookFolders.redownloadProblem(target, mayCreateParents: false) == nil)
            // Something else has taken its place.
            try make(target, files: ["other.txt"])
            try expect(NotebookFolders.redownloadProblem(target, mayCreateParents: false)?.contains("不是空的") == true)
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

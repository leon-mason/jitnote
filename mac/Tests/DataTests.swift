import Foundation

/// Ports of the Android NoteIndexTest, NoteAssetsTest, AppUpdatesTest and RepoListTest.

private func write(_ root: URL, _ path: String, _ text: String = "", modified: TimeInterval? = nil) throws {
    let file = root.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: file, atomically: true, encoding: .utf8)
    if let modified {
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: modified)], ofItemAtPath: file.path)
    }
}

enum NoteIndexTests {
    static let all: [TestCase] = [
        TestCase("buildsTheFileTreeLikeObsidian") { root in
            try write(root, "b.md")
            try write(root, "A.txt")
            try write(root, "会议/2026/x.md")
            try write(root, "会议/2026/y.md")
            try write(root, "会议/2025/z.md")
            try write(root, "会议/议程.md")
            try write(root, "技术/安卓/发布/r.md")
            try write(root, "附件/cat.png")
            try FileManager.default.createDirectory(at: root.appendingPathComponent("空文件夹"), withIntermediateDirectories: true)
            try write(root, ".obsidian/w.md")
            try write(root, ".gitignore", "x")

            let tree = NoteIndex.tree(in: root)
            // Folders first, then files with their extensions; Chinese names sort by pinyin: fu, hui, ji, kong.
            try expectEqual(tree.map(\.name), ["附件", "会议", "技术", "空文件夹", "A.txt", "b.md"])
            let meetings = tree[1]
            try expect(meetings.isFolder)
            try expectEqual(meetings.noteCount, 4)
            try expectEqual(meetings.children.map(\.name), ["2025", "2026", "议程.md"])
            try expectEqual(meetings.children[1].path, "会议/2026")
            try expectEqual(meetings.children[1].noteCount, 2)
            try expectEqual(meetings.children[2].path, "会议/议程.md")
            try expect(!meetings.children[2].isFolder)
            try expect(meetings.children[2].children.isEmpty)
            try expectEqual(tree[0].children.map(\.name), ["cat.png"])
            try expectEqual(tree[0].noteCount, 0)
            try expect(tree[3].children.isEmpty)
            try expectEqual(tree[2].children[0].children[0].children.map(\.name), ["r.md"])
        },

        TestCase("treeSortsByNameBothWays") { root in
            try write(root, "b.md"); try write(root, "a.md"); try write(root, "乙/x.md"); try write(root, "甲/x.md")
            try expectEqual(NoteIndex.tree(in: root, sort: .titleAsc).map(\.name), ["甲", "乙", "a.md", "b.md"])
            try expectEqual(NoteIndex.tree(in: root, sort: .titleDesc).map(\.name), ["乙", "甲", "b.md", "a.md"])
        },

        TestCase("treeSortsFilesByMinuteAndKeepsFoldersByName") { root in
            try write(root, "a.md", modified: 60_000); try write(root, "b.md", modified: 180_000); try write(root, "c.md", modified: 120_000)
            try write(root, "乙/x.md"); try write(root, "甲/x.md")
            try expectEqual(NoteIndex.tree(in: root, sort: .modifiedDesc).map(\.name), ["甲", "乙", "b.md", "c.md", "a.md"])
            try expectEqual(NoteIndex.tree(in: root, sort: .modifiedAsc).map(\.name), ["甲", "乙", "a.md", "c.md", "b.md"])
        },

        TestCase("treeBreaksTiesInTheSameMinuteByName") { root in
            try write(root, "b.md", modified: 60_000); try write(root, "a.md", modified: 60_030)
            try expectEqual(NoteIndex.tree(in: root, sort: .modifiedDesc).map(\.name), ["a.md", "b.md"])
        },

        TestCase("hiddenFilesOnlyWhenAskedAndNeverGit") { root in
            try write(root, "a.md")
            try write(root, ".gitignore", "x")
            try write(root, ".obsidian/templates/模板.md")
            try write(root, ".git/notes.md")

            try expectEqual(NoteIndex.tree(in: root).map(\.name), ["a.md"])

            let tree = NoteIndex.tree(in: root, showHidden: true)
            try expectEqual(tree.map(\.name), [".obsidian", ".gitignore", "a.md"])
            try expectEqual(tree[0].noteCount, 1)
        },

        TestCase("symlinkIsListedUnderItsOwnName") { root in
            try write(root, "AGENTS.md")
            try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("project_memory.md").path, withDestinationPath: "AGENTS.md")
            try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("CLAUDE.md").path, withDestinationPath: "@AGENTS.md")

            // Each entry keeps its own path: the sidebar uses it as the row id, and two rows with the
            // same id showed one file twice and hid the other.
            let tree = NoteIndex.tree(in: root)
            try expectEqual(tree.map(\.name), ["AGENTS.md", "CLAUDE.md", "project_memory.md"])
            try expectEqual(tree.map(\.path), ["AGENTS.md", "CLAUDE.md", "project_memory.md"])
        },

        TestCase("referenceOpensTheFileItPointsAt") { root in
            try write(root, "AGENTS.md", "rules")
            try write(root, "其他.md", "other")
            try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("CLAUDE.md").path, withDestinationPath: "@AGENTS.md")
            try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("project_memory.md").path, withDestinationPath: "AGENTS.md")
            try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("跳转.md").path, withDestinationPath: "@CLAUDE.md")
            try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("断了.md").path, withDestinationPath: "@没有.md")
            try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("出去.md").path, withDestinationPath: "/etc/passwd")
            try FileManager.default.createDirectory(at: root.appendingPathComponent("子目录"), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("子目录/索引.md").path, withDestinationPath: "@../AGENTS.md")
            try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("子目录/快捷方式.md").path, withDestinationPath: "../AGENTS.md")
            try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("甲.md").path, withDestinationPath: "@乙.md")
            try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("乙.md").path, withDestinationPath: "@甲.md")

            // An index (`@name`) and a shortcut both open the real file, including through another reference.
            try expectEqual(NoteIndex.resolveReference(at: root.appendingPathComponent("CLAUDE.md"), in: root), "AGENTS.md")
            try expectEqual(NoteIndex.resolveReference(at: root.appendingPathComponent("project_memory.md"), in: root), "AGENTS.md")
            try expectEqual(NoteIndex.resolveReference(at: root.appendingPathComponent("跳转.md"), in: root), "AGENTS.md")
            try expectEqual(NoteIndex.resolveReference(at: root.appendingPathComponent("子目录/索引.md"), in: root), "AGENTS.md")
            try expectEqual(NoteIndex.resolveReference(at: root.appendingPathComponent("子目录/快捷方式.md"), in: root), "AGENTS.md")
            try expect(NoteIndex.resolveReference(at: root.appendingPathComponent("AGENTS.md"), in: root) == nil)
            try expect(NoteIndex.resolveReference(at: root.appendingPathComponent("断了.md"), in: root) == nil)
            try expect(NoteIndex.resolveReference(at: root.appendingPathComponent("出去.md"), in: root) == nil)
            try expect(NoteIndex.resolveReference(at: root.appendingPathComponent("甲.md"), in: root) == nil)

            // Every reference in the folder names the same file, so that file is what the folder shows.
            try expectEqual(NoteIndex.referenceTarget(inFolder: "", root: root, showHidden: false), "AGENTS.md")
            try expectEqual(NoteIndex.referenceTarget(inFolder: "子目录", root: root, showHidden: false), "AGENTS.md")

            try write(root, "分叉/a.md")
            try write(root, "分叉/b.md")
            try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("分叉/一.md").path, withDestinationPath: "@a.md")
            try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("分叉/二.md").path, withDestinationPath: "@b.md")
            try expect(NoteIndex.referenceTarget(inFolder: "分叉", root: root, showHidden: false) == nil)

            try write(root, "隐藏/其他.md")
            try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("隐藏/.secret.md").path, withDestinationPath: "@其他.md")
            try expect(NoteIndex.referenceTarget(inFolder: "隐藏", root: root, showHidden: false) == nil)
            try expectEqual(NoteIndex.referenceTarget(inFolder: "隐藏", root: root, showHidden: true), "隐藏/其他.md")
        },
    ]
}

enum NoteAssetsTests {
    static func notebook(_ root: URL) throws -> NoteAssets {
        let book = root.appendingPathComponent("notebook")
        for path in ["日记/assets/my photo.png", "附件/封面.png", "附件/深/封面.png", "图库/2026/封面.png", ".git/objects/封面.png"] {
            try write(book, path, "x")
        }
        try write(root, "outside.png", "x")
        return NoteAssets(root: book)
    }

    static let all: [TestCase] = [
        TestCase("relativeToTheNote") { root in
            let assets = try notebook(root)
            try expectEqual(assets.resolve(noteFolder: "日记", reference: "assets/my photo.png"), "日记/assets/my photo.png")
            try expectEqual(assets.resolve(noteFolder: "日记", reference: "./assets/my photo.png"), "日记/assets/my photo.png")
        },
        TestCase("relativeToTheNotebookRoot") { root in
            let assets = try notebook(root)
            try expectEqual(assets.resolve(noteFolder: "日记", reference: "附件/封面.png"), "附件/封面.png")
            try expectEqual(assets.resolve(noteFolder: "日记", reference: "/附件/封面.png"), "附件/封面.png")
        },
        TestCase("byNameAnywhereShortestPathFirst") { root in
            let assets = try notebook(root)
            try expectEqual(assets.resolve(noteFolder: "日记", reference: "封面.png"), "附件/封面.png")
            try expectEqual(assets.resolve(noteFolder: "", reference: "2026/封面.png"), "图库/2026/封面.png")
            try expectEqual(assets.resolve(noteFolder: "", reference: "MY PHOTO.png"), "日记/assets/my photo.png")
        },
        TestCase("neverLeavesTheNotebookOrReadsGitInternals") { root in
            let assets = try notebook(root)
            try expect(assets.resolve(noteFolder: "日记", reference: "../../outside.png") == nil)
            try expect(assets.resolve(noteFolder: "", reference: "outside.png") == nil)
            try expect(assets.resolve(noteFolder: "", reference: "objects/封面.png") == nil)
            try expect(assets.resolve(noteFolder: "", reference: "https://example.com/a.png") == nil)
            try expect(assets.resolve(noteFolder: "", reference: "missing.png") == nil)
        },
    ]
}

enum AppUpdatesTests {
    static func json(_ text: String) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
    }

    static let all: [TestCase] = [
        TestCase("comparesVersionsNumerically") { _ in
            try expect(AppUpdates.isNewer("v0.2.0", than: "0.1.0"))
            try expect(AppUpdates.isNewer("0.10.0", than: "0.9.3"))
            try expect(AppUpdates.isNewer("1.0", than: "0.9.9"))
            try expect(AppUpdates.isNewer("0.1.1", than: "0.1"))
            try expect(!AppUpdates.isNewer("v0.1.0", than: "0.1.0"))
            try expect(!AppUpdates.isNewer("0.1", than: "0.1.0"))
            try expect(!AppUpdates.isNewer("0.0.9", than: "0.1.0"))
            try expect(!AppUpdates.isNewer("not-a-version", than: "0.1.0"))
        },
        TestCase("readsTheMacBuildFromARelease") { _ in
            let release = AppUpdates.parseRelease(json("""
            {
              "tag_name": "v0.3.0", "draft": false, "prerelease": false,
              "body": "· 有 Mac 版了\\r\\n· 修复同步偶尔失败\\r\\n",
              "assets": [
                {"name": "jitnote-0.3.0.apk", "size": 2400000, "browser_download_url": "https://example.com/a.apk"},
                {"name": "Jitnote-mac-0.3.0.zip", "size": 9000000, "browser_download_url": "https://example.com/m.zip"}
              ]
            }
            """))!
            try expectEqual(release.version, "0.3.0")
            try expectEqual(release.notes, "· 有 Mac 版了\n· 修复同步偶尔失败")
            try expectEqual(release.downloadUrl.absoluteString, "https://example.com/m.zip")
            try expectEqual(release.size, 9_000_000)
            try expect(!release.isDiskImage)
        },
        TestCase("picksThePackageForThisMacsChip") { _ in
            let release = json("""
            {
              "tag_name": "v0.5.0",
              "assets": [
                {"name": "jitnote-0.5.0.apk", "size": 1, "browser_download_url": "https://example.com/a.apk"},
                {"name": "Jitnote-mac-intel-0.5.0.dmg", "size": 2, "browser_download_url": "https://example.com/intel.dmg"},
                {"name": "Jitnote-mac-apple-silicon-0.5.0.zip", "size": 3, "browser_download_url": "https://example.com/arm.zip"},
                {"name": "Jitnote-mac-apple-silicon-0.5.0.dmg", "size": 4, "browser_download_url": "https://example.com/arm.dmg"}
              ]
            }
            """)
            try expectEqual(AppUpdates.parseRelease(release, chip: "apple-silicon")!.downloadUrl.absoluteString, "https://example.com/arm.dmg")
            try expectEqual(AppUpdates.parseRelease(release, chip: "intel")!.downloadUrl.absoluteString, "https://example.com/intel.dmg")
            let armOnly = json(#"{"tag_name": "v0.5.0", "assets": [{"name": "Jitnote-mac-apple-silicon-0.5.0.dmg", "size": 4, "browser_download_url": "https://example.com/arm.dmg"}]}"#)
            try expect(AppUpdates.parseRelease(armOnly, chip: "intel") == nil)
        },

        TestCase("prefersTheDiskImageWhenThereIsOne") { _ in
            let release = AppUpdates.parseRelease(json("""
            {
              "tag_name": "v0.4.0",
              "assets": [
                {"name": "Jitnote-mac-0.4.0.zip", "size": 9000000, "browser_download_url": "https://example.com/m.zip"},
                {"name": "Jitnote-mac-0.4.0.dmg", "size": 9500000, "browser_download_url": "https://example.com/m.dmg"}
              ]
            }
            """))!
            try expectEqual(release.downloadUrl.absoluteString, "https://example.com/m.dmg")
            try expectEqual(release.size, 9_500_000)
            try expect(release.isDiskImage)
        },
        TestCase("ignoresReleasesWithoutAMacBuildOrNotYetPublic") { _ in
            let apkOnly = #"[{"name": "a.apk", "size": 1, "browser_download_url": "https://example.com/a.apk"}]"#
            let mac = #"[{"name": "Jitnote-mac-1.zip", "size": 1, "browser_download_url": "https://example.com/m.zip"}]"#
            try expect(AppUpdates.parseRelease(json(#"{"tag_name": "v0.2.0", "assets": \#(apkOnly)}"#)) == nil)
            try expect(AppUpdates.parseRelease(json(#"{"tag_name": "v0.2.0", "prerelease": true, "assets": \#(mac)}"#)) == nil)
            try expect(AppUpdates.parseRelease(json(#"{"tag_name": "v0.2.0", "draft": true, "assets": \#(mac)}"#)) == nil)
            try expectEqual(AppUpdates.parseRelease(json(#"{"tag_name": "v0.2.0", "body": null, "assets": \#(mac)}"#))!.notes, "")
        },
    ]
}

enum HostingApiTests {
    static let all: [TestCase] = [
        TestCase("readsGiteeRepositories") { _ in
            let repos = HostingApi.parseRepos(try JSONSerialization.jsonObject(with: Data("""
            [{
              "path": "notes", "name": "我的笔记", "owner": {"login": "zhl"},
              "namespace": {"path": "zhl"}, "description": "", "private": true,
              "html_url": "https://gitee.com/zhl/notes.git",
              "pushed_at": "2026-10-28T10:00:00+08:00", "updated_at": "2026-10-29T10:00:00+08:00"
            }, {
              "path": "jitnote-ab12", "name": "jitnote-ab12", "owner": {"login": "zhl"},
              "description": "[Jitnote] 读书笔记", "private": true,
              "html_url": "https://gitee.com/zhl/jitnote-ab12.git"
            }]
            """.utf8)) as! [Any])
            try expectEqual(repos[0].path, "notes")
            try expectEqual(repos[0].displayName, "我的笔记")
            try expectEqual(repos[0].cloneUrl, "https://gitee.com/zhl/notes.git")
            try expect(!repos[0].isNotebook)
            try expect(repos[0].isPrivate)
            try expectEqual(repos[0].owner, "zhl")
            try expectEqual(repos[0].updatedAt, 1_793_152_800_000)
            try expect(repos[1].isNotebook)
            try expectEqual(repos[1].displayName, "读书笔记")
            try expect(repos[1].updatedAt == nil)
        },
        TestCase("readsGitHubRepositories") { _ in
            let repo = HostingApi.parseRepos(try JSONSerialization.jsonObject(with: Data("""
            [{
              "name": "notes", "full_name": "acme/notes", "owner": {"login": "acme"},
              "private": false, "html_url": "https://github.com/acme/notes",
              "clone_url": "https://github.com/acme/notes.git", "description": null,
              "pushed_at": "2026-10-30T01:02:03Z", "size": 204800
            }]
            """.utf8)) as! [Any])[0]
            try expectEqual(repo.displayName, "notes")
            try expectEqual(repo.cloneUrl, "https://github.com/acme/notes.git")
            try expect(!repo.isPrivate)
            try expectEqual(repo.owner, "acme")
            try expectEqual(repo.sizeKb, 204800)
        },
        TestCase("normalizesPastedAddresses") { _ in
            try expectEqual(RepoUrls.toCloneUrl("https://gitee.com/zhl/notes"), "https://gitee.com/zhl/notes.git")
            try expectEqual(RepoUrls.toCloneUrl(" https://gitee.com/zhl/notes/tree/master/日记 "), "https://gitee.com/zhl/notes.git")
            try expectEqual(RepoUrls.toCloneUrl("https://www.github.com/a/b.git/"), "https://github.com/a/b.git")
            try expectEqual(RepoUrls.toCloneUrl("https://git.example.com/team/notes"), "https://git.example.com/team/notes")
            try expectEqual(RepoUrls.toCloneUrl("https://gitee.com/zhl"), "https://gitee.com/zhl")
        },
        TestCase("derivesRepositoryNames") { _ in
            try expectEqual(RepoNames.fromName("Work Notes"), "work-notes")
            try expect(RepoNames.fromName("读书笔记").hasPrefix("notes-"))
            try expect(RepoNames.isValid("notes-ab12"))
            try expect(!RepoNames.isValid("1notes"))
        },
    ]
}

enum FileTreeTests {
    private static func file(_ path: String) -> NoteIndex.Entry {
        NoteIndex.Entry(path: path, name: String(path.split(separator: "/").last ?? ""), isFolder: false, children: [], noteCount: 0, modified: 0)
    }

    private static func folder(_ path: String, _ children: NoteIndex.Entry...) -> NoteIndex.Entry {
        NoteIndex.Entry(path: path, name: String(path.split(separator: "/").last ?? ""), isFolder: true, children: children, noteCount: 0, modified: 0)
    }

    private static let tree = [
        folder("会议", folder("会议/2026", file("会议/2026/周会.md"))),
        folder("会议记录"),
        file("a.md"),
    ]

    static let all: [TestCase] = [
        TestCase("visibleRowsOnlyShowOpenFolders") { _ in
            let rows = FileTree.visibleRows(tree, expanded: ["会议"])
            try expectEqual(rows.map(\.entry.name), ["会议", "2026", "会议记录", "a.md"])
            try expectEqual(rows.map(\.depth), [0, 1, 0, 0])
        },

        TestCase("visibleRowsIgnoreStaleExpandedPaths") { _ in
            let rows = FileTree.visibleRows(tree, expanded: ["不存在/的"])
            try expectEqual(rows.map(\.entry.name), ["会议", "会议记录", "a.md"])
        },

        TestCase("currentFolderOfAFolderIsItself") { _ in
            try expectEqual(FileTree.currentFolder(tree, highlighted: "会议/2026"), "会议/2026")
        },

        TestCase("currentFolderOfAFileIsItsParent") { _ in
            try expectEqual(FileTree.currentFolder(tree, highlighted: "会议/2026/周会.md"), "会议/2026")
            try expectEqual(FileTree.currentFolder(tree, highlighted: "a.md"), "")
        },

        TestCase("currentFolderFallsBackToRootWhenMissing") { _ in
            try expectEqual(FileTree.currentFolder(tree, highlighted: "已删除/x.md"), "")
            try expectEqual(FileTree.currentFolder(tree, highlighted: ""), "")
        },

        TestCase("parentAndAncestors") { _ in
            try expectEqual(FileTree.parent("会议/2026"), "会议")
            try expectEqual(FileTree.parent("会议"), "")
            try expectEqual(FileTree.ancestors("会议/2026/周会.md"), ["会议", "会议/2026"])
        },

        TestCase("renameMovesTheFolderAndWhatIsInside") { _ in
            try expectEqual(FileTree.renamed(["会议", "会议/2026", "b"], old: "会议", new: "工作"), ["工作", "工作/2026", "b"])
        },

        TestCase("renameDoesNotTouchSimilarNames") { _ in
            try expectEqual(FileTree.renamed(["会议", "会议记录"], old: "会议", new: "工作"), ["工作", "会议记录"])
            try expectEqual(FileTree.moved("会议记录/x.md", old: "会议", new: "工作"), "会议记录/x.md")
        },

        TestCase("removeDropsTheFolderAndWhatIsInside") { _ in
            try expectEqual(FileTree.removed(["会议", "会议/2026", "会议记录"], path: "会议"), ["会议记录"])
        },

        TestCase("autoSyncOnColdStartOnlyOnceAndAfterAMinuteAway") { _ in
            try expect(AutoSync.shouldStart(enabled: true, busy: false, hasNotebook: true, awayMs: nil, launchHandled: false))
            try expect(!AutoSync.shouldStart(enabled: true, busy: false, hasNotebook: true, awayMs: nil, launchHandled: true))
            try expect(!AutoSync.shouldStart(enabled: true, busy: false, hasNotebook: true, awayMs: AutoSync.minAwayMs - 1, launchHandled: true))
            try expect(AutoSync.shouldStart(enabled: true, busy: false, hasNotebook: true, awayMs: AutoSync.minAwayMs, launchHandled: true))
            try expect(!AutoSync.shouldStart(enabled: false, busy: false, hasNotebook: true, awayMs: nil, launchHandled: false))
            try expect(!AutoSync.shouldStart(enabled: true, busy: true, hasNotebook: true, awayMs: nil, launchHandled: false))
            try expect(!AutoSync.shouldStart(enabled: true, busy: false, hasNotebook: false, awayMs: nil, launchHandled: false))
        },

        TestCase("oldStateFileKeepsAccountsAndNotebooks") { _ in
            let json = #"""
            {
              "accounts": [{"id":"a1","provider":"GITHUB","login":"me","email":"me@example.com","createdAt":1}],
              "notebooks": [{"id":"n1","name":"笔记","accountId":"a1","remoteUrl":"https://github.com/me/notes.git","dir":"notes","createdAt":2}],
              "currentNotebookId": "n1",
              "noteSort": "MODIFIED_DESC",
              "showHiddenFiles": true
            }
            """#
            let state = try JSONDecoder().decode(AppState.self, from: Data(json.utf8))
            try expectEqual(state.accounts.count, 1)
            try expectEqual(state.notebooks.count, 1)
            try expectEqual(state.currentNotebookId, "n1")
            try expect(state.showHiddenFiles)
            try expect(!state.syncOnLaunch)
            try expectEqual(state.fileSort, .titleAsc)
            try expectEqual(state.defaultViewMode, .edit)
            try expectEqual(state.expandedFolders, [:])
        },
    ]
}

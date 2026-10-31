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
        TestCase("listsEveryNoteInEveryFolderButNotOtherFiles") { root in
            try write(root, "读书清单.md")
            try write(root, "会议/2026/周会.md")
            try write(root, "技术/安卓/发布.markdown")
            try write(root, "技术/随手记.txt")
            try write(root, "附件/cat.png")
            try write(root, ".obsidian/workspace.md")
            try write(root, ".git/HEAD")

            let notes = NoteIndex.notes(in: root, sort: .titleAsc)
            try expectEqual(notes.map(\.title).sorted(), ["发布", "周会", "读书清单", "随手记"])
            try expectEqual(notes.first { $0.title == "周会" }!.folder, "会议/2026")
            try expectEqual(notes.first { $0.title == "读书清单" }!.folder, "")
            try expectEqual(notes.first { $0.title == "发布" }!.path, "技术/安卓/发布.markdown")
        },

        TestCase("filtersByFolderIncludingSubfolders") { root in
            try write(root, "a.md")
            try write(root, "技术/b.md")
            try write(root, "技术/安卓/c.md")
            try write(root, "技术员/d.md")

            try expectEqual(NoteIndex.notes(in: root, sort: .titleAsc, folder: "技术").map(\.title), ["b", "c"])
            try expectEqual(NoteIndex.notes(in: root, sort: .titleAsc, folder: "技术/安卓").map(\.title), ["c"])
        },

        TestCase("sortsByTimeOrTitle") { root in
            try write(root, "b.md", modified: 3_000)
            try write(root, "a.md", modified: 1_000)
            try write(root, "C.md", modified: 2_000)

            try expectEqual(NoteIndex.notes(in: root, sort: .modifiedDesc).map(\.title), ["b", "C", "a"])
            try expectEqual(NoteIndex.notes(in: root, sort: .modifiedAsc).map(\.title), ["a", "C", "b"])
            try expectEqual(NoteIndex.notes(in: root, sort: .titleAsc).map(\.title), ["a", "b", "C"])
            try expectEqual(NoteIndex.notes(in: root, sort: .titleDesc).map(\.title), ["C", "b", "a"])
        },

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
            try expectEqual(meetings.children!.map(\.name), ["2025", "2026", "议程.md"])
            try expectEqual(meetings.children![1].path, "会议/2026")
            try expectEqual(meetings.children![1].noteCount, 2)
            try expectEqual(meetings.children![2].path, "会议/议程.md")
            try expect(!meetings.children![2].isFolder)
            try expect(meetings.children![2].children == nil)
            try expectEqual(tree[0].children!.map(\.name), ["cat.png"])
            try expectEqual(tree[0].noteCount, 0)
            try expect(tree[3].children == nil)
            try expectEqual(tree[2].children![0].children![0].children!.map(\.name), ["r.md"])
        },

        TestCase("hiddenFilesOnlyWhenAskedAndNeverGit") { root in
            try write(root, "a.md")
            try write(root, ".gitignore", "x")
            try write(root, ".obsidian/templates/模板.md")
            try write(root, ".git/notes.md")

            try expectEqual(NoteIndex.notes(in: root, sort: .titleAsc).map(\.title), ["a"])
            try expectEqual(NoteIndex.tree(in: root).map(\.name), ["a.md"])

            try expectEqual(Set(NoteIndex.notes(in: root, sort: .titleAsc, showHidden: true).map(\.title)), ["a", "模板"])
            let tree = NoteIndex.tree(in: root, showHidden: true)
            try expectEqual(tree.map(\.name), [".obsidian", ".gitignore", "a.md"])
            try expectEqual(tree[0].noteCount, 1)
        },

        TestCase("previewSkipsFrontMatterTitleAndMarkup") { _ in
            try expectEqual(
                NoteIndex.preview("---\ntags: [会议]\n---\n# 周会记录\n\n> 下周上线**检查更新**功能\n\n- 需要先发\n- [ ] 一个版本\n"),
                "下周上线检查更新功能 需要先发 一个版本"
            )
            try expectEqual(NoteIndex.preview("看这张图\n![猫](assets/cat.png)\n![[cat.png]]"), "看这张图 猫")
            try expectEqual(NoteIndex.preview("# 只有标题\n"), "")
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
                {"name": "git-notebook-0.3.0.apk", "size": 2400000, "browser_download_url": "https://example.com/a.apk"},
                {"name": "GitNotebook-mac-0.3.0.zip", "size": 9000000, "browser_download_url": "https://example.com/m.zip"}
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
                {"name": "git-notebook-0.5.0.apk", "size": 1, "browser_download_url": "https://example.com/a.apk"},
                {"name": "GitNotebook-mac-intel-0.5.0.dmg", "size": 2, "browser_download_url": "https://example.com/intel.dmg"},
                {"name": "GitNotebook-mac-apple-silicon-0.5.0.zip", "size": 3, "browser_download_url": "https://example.com/arm.zip"},
                {"name": "GitNotebook-mac-apple-silicon-0.5.0.dmg", "size": 4, "browser_download_url": "https://example.com/arm.dmg"}
              ]
            }
            """)
            try expectEqual(AppUpdates.parseRelease(release, chip: "apple-silicon")!.downloadUrl.absoluteString, "https://example.com/arm.dmg")
            try expectEqual(AppUpdates.parseRelease(release, chip: "intel")!.downloadUrl.absoluteString, "https://example.com/intel.dmg")
            let armOnly = json(#"{"tag_name": "v0.5.0", "assets": [{"name": "GitNotebook-mac-apple-silicon-0.5.0.dmg", "size": 4, "browser_download_url": "https://example.com/arm.dmg"}]}"#)
            try expect(AppUpdates.parseRelease(armOnly, chip: "intel") == nil)
        },

        TestCase("prefersTheDiskImageWhenThereIsOne") { _ in
            let release = AppUpdates.parseRelease(json("""
            {
              "tag_name": "v0.4.0",
              "assets": [
                {"name": "GitNotebook-mac-0.4.0.zip", "size": 9000000, "browser_download_url": "https://example.com/m.zip"},
                {"name": "GitNotebook-mac-0.4.0.dmg", "size": 9500000, "browser_download_url": "https://example.com/m.dmg"}
              ]
            }
            """))!
            try expectEqual(release.downloadUrl.absoluteString, "https://example.com/m.dmg")
            try expectEqual(release.size, 9_500_000)
            try expect(release.isDiskImage)
        },
        TestCase("ignoresReleasesWithoutAMacBuildOrNotYetPublic") { _ in
            let apkOnly = #"[{"name": "a.apk", "size": 1, "browser_download_url": "https://example.com/a.apk"}]"#
            let mac = #"[{"name": "GitNotebook-mac-1.zip", "size": 1, "browser_download_url": "https://example.com/m.zip"}]"#
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
              "path": "gitnote-ab12", "name": "gitnote-ab12", "owner": {"login": "zhl"},
              "description": "[GitNotebook] 读书笔记", "private": true,
              "html_url": "https://gitee.com/zhl/gitnote-ab12.git"
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

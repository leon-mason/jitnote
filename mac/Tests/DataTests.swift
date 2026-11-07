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

enum MoveFilesTests {
    static func read(_ root: URL, _ path: String) -> String? {
        try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    static func exists(_ root: URL, _ path: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path)
    }

    static func message(_ body: () throws -> Void) -> String? {
        do { try body() } catch { return (error as? SyncError)?.message ?? "\(error)" }
        return nil
    }

    static let all: [TestCase] = [
        TestCase("movesAFileIntoAFolder") { root in
            try write(root, "a.md", "内容")
            try FileManager.default.createDirectory(at: root.appendingPathComponent("工作"), withIntermediateDirectories: true)
            let moved = try NoteFiles.move(root.appendingPathComponent("a.md"), into: root.appendingPathComponent("工作"))
            try expectEqual(NoteIndex.relativePath(of: moved, in: root), "工作/a.md")
            try expectEqual(read(root, "工作/a.md"), "内容")
            try expect(!exists(root, "a.md"))
        },
        TestCase("movesAFolderWithEverythingInside") { root in
            try write(root, "会议/2026/x.md", "纪要")
            try FileManager.default.createDirectory(at: root.appendingPathComponent("工作"), withIntermediateDirectories: true)
            try NoteFiles.move(root.appendingPathComponent("会议"), into: root.appendingPathComponent("工作"))
            try expectEqual(read(root, "工作/会议/2026/x.md"), "纪要")
            try expect(!exists(root, "会议"))
        },
        TestCase("movesToTheNotebookRoot") { root in
            try write(root, "工作/a.md")
            try NoteFiles.move(root.appendingPathComponent("工作/a.md"), into: root)
            try expect(exists(root, "a.md"))
        },
        TestCase("refusesWhenTheNameIsTaken") { root in
            try write(root, "a.md", "新")
            try write(root, "工作/a.md", "旧")
            let error = message { try NoteFiles.move(root.appendingPathComponent("a.md"), into: root.appendingPathComponent("工作")) }
            try expectEqual(error, "目标文件夹里已有同名文件")
            try expectEqual(read(root, "a.md"), "新")
            try expectEqual(read(root, "工作/a.md"), "旧")
        },
        TestCase("aFolderCannotGoIntoItself") { root in
            try write(root, "会议/2026/x.md")
            try expect(message { try NoteFiles.move(root.appendingPathComponent("会议"), into: root.appendingPathComponent("会议/2026")) } != nil)
            try expect(message { try NoteFiles.move(root.appendingPathComponent("会议"), into: root.appendingPathComponent("会议")) } != nil)
            try expect(exists(root, "会议/2026/x.md"))
        },
        TestCase("movingToWhereItIsChangesNothing") { root in
            try write(root, "a.md", "内容")
            try NoteFiles.move(root.appendingPathComponent("a.md"), into: root)
            try expectEqual(read(root, "a.md"), "内容")
        },
    ]
}

enum BrokenImageCheckTests {
    static func notebook(_ root: URL) throws -> URL {
        let book = root.appendingPathComponent("notebook")
        let files: [(String, String)] = [
            ("笔记/a.md", "![封面](img/a.png)"),
            ("笔记/img/a.png", "x"),
            ("日志/b.md", "![](../笔记/img/a.png)"),
            ("c.md", "![](/笔记/img/a.png)"),
            ("d.md", "![](https://example.com/x.png) ![[a.png]] ![](missing.png)"),
            ("e.md", "![](my%20photo.png) ![](<my photo.png>)"),
            ("my photo.png", "x"),
            ("g.md", "```\n![](root.png)\n```"),
            ("root.png", "x"),
        ]
        for (path, text) in files { try write(book, path, text) }
        return book
    }

    static func broken(_ book: URL, _ source: String, _ target: String) -> [String] {
        BrokenImageCheck.notes(root: book, moving: source, to: target)
    }

    static let all: [TestCase] = [
        TestCase("aNoteMovedAwayFromItsImages") { root in
            let book = try notebook(root)
            try expectEqual(broken(book, "笔记/a.md", "工作"), ["笔记/a.md"])
        },
        TestCase("aFolderMovedTogetherWithItsImages") { root in
            let book = try notebook(root)
            // Only the notes that point into the folder from outside lose their image.
            try expectEqual(broken(book, "笔记", "工作"), ["c.md", "日志/b.md"])
            try expectEqual(broken(book, "笔记", ""), [])
        },
        TestCase("anImageMovedAwayFromItsNotes") { root in
            let book = try notebook(root)
            try expectEqual(broken(book, "笔记/img/a.png", ""), ["c.md", "日志/b.md", "笔记/a.md"])
            try expectEqual(broken(book, "my photo.png", "工作"), ["e.md"])
        },
        TestCase("parentFolderReferencesAreFollowed") { root in
            let book = try notebook(root)
            try expectEqual(broken(book, "日志/b.md", "工作"), [])
            try expectEqual(broken(book, "日志/b.md", "笔记"), [])
            try expectEqual(broken(book, "日志/b.md", "工作/深"), ["日志/b.md"])
            try expectEqual(broken(book, "c.md", "笔记"), [])
        },
        TestCase("encodedAndBracketedPathsCountOncePerNote") { root in
            let book = try notebook(root)
            try expectEqual(broken(book, "e.md", "工作"), ["e.md"])
        },
        TestCase("onlyReferencesThatWorkedBeforeCount") { root in
            let book = try notebook(root)
            try expectEqual(broken(book, "d.md", "工作"), [])
            try expectEqual(broken(book, "root.png", "工作"), [])
        },
        TestCase("readsOnly") { root in
            let book = try notebook(root)
            func snapshot() throws -> [String: String] {
                var all: [String: String] = [:]
                let walker = FileManager.default.enumerator(at: book, includingPropertiesForKeys: [.isRegularFileKey])
                while let url = walker?.nextObject() as? URL {
                    guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
                    all[url.path] = try String(contentsOf: url, encoding: .utf8)
                }
                return all
            }
            let before = try snapshot()
            _ = broken(book, "笔记", "工作")
            try expect(try snapshot() == before)
        },
    ]
}

enum AppUpdatesTests {
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
        TestCase("readsTheMacBuildFromLatestJson") { _ in
            let release = try AppUpdates.parseManifest(manifest, package: "mac-apple-silicon")!
            try expectEqual(release.version, "0.11.0")
            try expectEqual(release.notes, "· 插入图片\n· 修复同步偶尔失败")
            // Gitee first: it is the fast one for most users; GitHub is the fallback.
            try expectEqual(release.downloadUrls.map(\.absoluteString), [
                "https://gitee.com/shitoupapa/jitnote/releases/download/v0.11.0/Jitnote-mac-apple-silicon-0.11.0.dmg",
                "https://github.com/leon-mason/jitnote/releases/download/v0.11.0/Jitnote-mac-apple-silicon-0.11.0.dmg",
            ])
            try expectEqual(release.size, 5_911_784)
            try expectEqual(release.sha256, shaOfHello)
            try expect(release.isDiskImage)
            try expect(try AppUpdates.parseManifest(manifest, package: "mac-intel") == nil)
        },
        TestCase("rejectsUnreadableLatestJsonAndIgnoresIncompletePackages") { _ in
            try expect((try? AppUpdates.parseManifest(Data("<html>Not Found</html>".utf8), package: "mac-apple-silicon")) == nil)
            try expect((try? AppUpdates.parseManifest(Data(#"{"packages": {}}"#.utf8), package: "mac-apple-silicon")) == nil)
            try expect(try AppUpdates.parseManifest(Data(#"{"version": "0.11.0", "packages": {}}"#.utf8), package: "mac-apple-silicon") == nil)
            let noChecksum = Data(String(decoding: manifest, as: UTF8.self).replacingOccurrences(of: shaOfHello, with: "nope").utf8)
            try expect(try AppUpdates.parseManifest(noChecksum, package: "mac-apple-silicon") == nil)
        },
        TestCase("takesTheFirstAnswerWithoutCancellingTheOther") { _ in
            let slowFinished = Flag()
            let attempts: [@Sendable () async throws -> String] = [
                { throw URLError(.cannotConnectToHost) },
                { try await Task.sleep(nanoseconds: 50_000_000); return "github" },
                { try await Task.sleep(nanoseconds: 300_000_000); slowFinished.set(); return "slow" },
            ]
            let result = try waitFor { try await AppUpdates.firstSuccess(attempts) }
            try expectEqual(result, "github")
            // The slow request still runs to the end: GitHub counts it as a download.
            let deadline = Date().addingTimeInterval(5)
            while !slowFinished.value && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
            try expect(slowFinished.value)
        },
        TestCase("failsOnlyWhenEverySiteFailed") { _ in
            let attempts: [@Sendable () async throws -> String] = [
                { throw URLError(.cannotConnectToHost) },
                { try await Task.sleep(nanoseconds: 20_000_000); throw URLError(.timedOut) },
            ]
            let outcome = try? waitFor { try await AppUpdates.firstSuccess(attempts) }
            try expect(outcome == nil)
        },
        TestCase("keepsOnlyADownloadWithTheRightChecksum") { dir in
            let file = dir.appendingPathComponent("update.dmg")
            let gitee = URL(string: "https://gitee.com/x.dmg")!
            let github = URL(string: "https://github.com/x.dmg")!
            var tried: [URL] = []
            // Gitee hands out a different file, GitHub the right one: GitHub's is kept.
            try waitFor {
                try await AppUpdates.downloadVerified([gitee, github], to: file, size: 5, sha256: shaOfHello) { url, target in
                    tried.append(url)
                    try Data((url == gitee ? "HELLO" : "hello").utf8).write(to: target)
                }
            }
            try expectEqual(tried, [gitee, github])
            try expectEqual(try String(contentsOf: file), "hello")
            // Nothing matches: no file is left behind to install.
            let outcome: Void? = try? waitFor {
                try await AppUpdates.downloadVerified([gitee, github], to: file, size: 5, sha256: shaOfHello) { _, target in
                    try Data("HELLO".utf8).write(to: target)
                }
            }
            try expect(outcome == nil)
            try expect(!FileManager.default.fileExists(atPath: file.path))
        },
    ]

    /// SHA-256 of the five bytes "hello".
    static let shaOfHello = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"

    static let manifest = Data("""
    {
      "format": 1, "version": "0.11.0", "notes": "· 插入图片\\r\\n· 修复同步偶尔失败\\n",
      "packages": {
        "android": {"name": "jitnote-0.11.0.apk", "size": 2557137, "sha256": "\(shaOfHello)",
                    "gitee": "https://gitee.com/a.apk", "github": "https://github.com/a.apk"},
        "mac-apple-silicon": {
          "name": "Jitnote-mac-apple-silicon-0.11.0.dmg", "size": 5911784, "sha256": "\(shaOfHello)",
          "gitee": "https://gitee.com/shitoupapa/jitnote/releases/download/v0.11.0/Jitnote-mac-apple-silicon-0.11.0.dmg",
          "github": "https://github.com/leon-mason/jitnote/releases/download/v0.11.0/Jitnote-mac-apple-silicon-0.11.0.dmg"
        }
      }
    }
    """.utf8)
}

/// Thread-safe flag for tests whose work finishes on another task.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var isSet = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return isSet }
    func set() { lock.lock(); isSet = true; lock.unlock() }
}

/// Runs async code from the synchronous test runner.
func waitFor<T>(_ body: @escaping () async throws -> T) throws -> T {
    let done = DispatchSemaphore(value: 0)
    var outcome: Result<T, Error>!
    Task.detached {
        do { outcome = .success(try await body()) } catch { outcome = .failure(error) }
        done.signal()
    }
    done.wait()
    return try outcome.get()
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

        TestCase("canMoveOnlyToAnotherPlaceOutsideItself") { _ in
            try expect(FileTree.canMove("a/b.md", into: ""))
            try expect(FileTree.canMove("b.md", into: "a"))
            try expect(!FileTree.canMove("a/b.md", into: "a"))
            try expect(!FileTree.canMove("b.md", into: ""))
            try expect(!FileTree.canMove("a", into: "a"))
            try expect(!FileTree.canMove("a", into: "a/c"))
            try expect(FileTree.canMove("a", into: "ab"))
            try expect(FileTree.canMove("a/b", into: ""))
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

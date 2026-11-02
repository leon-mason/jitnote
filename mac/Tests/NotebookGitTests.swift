import CGit2
import Foundation

/// The same cases as the Android `NotebookGitTest`, so both apps merge the same way.
enum NotebookGitTests {
    static let author = Author(name: "Tester", email: "tester@example.com")

    struct Cloud {
        let root: URL
        var url: String { root.appendingPathComponent("cloud.git").path }

        init(_ root: URL) throws {
            self.root = root
            Git2.initialize()
            var options = git_repository_init_options()
            try Git2.check(git_repository_init_options_init(&options, UInt32(GIT_REPOSITORY_INIT_OPTIONS_VERSION)))
            options.flags = GIT_REPOSITORY_INIT_BARE.rawValue | GIT_REPOSITORY_INIT_MKPATH.rawValue
            var repo: OpaquePointer?
            try "main".withCString { head in
                options.initial_head = head
                try Git2.check(git_repository_init_ext(&repo, root.appendingPathComponent("cloud.git").path, &options))
            }
            git_repository_free(repo)
        }

        func device(_ name: String) throws -> NotebookGit {
            try NotebookGit.clone(url: url, into: root.appendingPathComponent(name), credentials: nil)
        }
    }

    static func write(_ git: NotebookGit, _ path: String, _ text: String) throws {
        let file = git.workTree.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
    }

    static func read(_ git: NotebookGit, _ path: String) throws -> String {
        try String(contentsOf: git.workTree.appendingPathComponent(path), encoding: .utf8)
    }

    @discardableResult
    static func sync(_ git: NotebookGit, _ name: String = "phone") throws -> SyncResult {
        try git.sync(credentials: nil, author: author, device: name)
    }

    /// Commit summaries on HEAD, newest first.
    static func log(_ git: NotebookGit) throws -> [String] {
        try withRepo(git) { repo in
            var walk: OpaquePointer?
            try Git2.check(git_revwalk_new(&walk, repo))
            defer { git_revwalk_free(walk) }
            try Git2.check(git_revwalk_sorting(walk, GIT_SORT_TOPOLOGICAL.rawValue | GIT_SORT_TIME.rawValue))
            try Git2.check(git_revwalk_push_head(walk))
            var id = git_oid()
            var messages: [String] = []
            while git_revwalk_next(&id, walk) == 0 {
                var commit: OpaquePointer?
                try Git2.check(git_commit_lookup(&commit, repo, &id))
                messages.append(String(cString: git_commit_summary(commit)))
                git_commit_free(commit)
            }
            return messages
        }
    }

    static func withRepo<T>(_ git: NotebookGit, _ body: (OpaquePointer) throws -> T) throws -> T {
        var repo: OpaquePointer?
        try Git2.check(git_repository_open(&repo, git.workTree.path))
        defer { git_repository_free(repo) }
        return try body(repo!)
    }

    static func configString(_ git: NotebookGit, _ name: String) throws -> String? {
        try withRepo(git) { repo in
            var config: OpaquePointer?
            try Git2.check(git_repository_config(&config, repo))
            defer { git_config_free(config) }
            var buffer = git_buf()
            defer { git_buf_dispose(&buffer) }
            guard git_config_get_string_buf(&buffer, config, name) == 0 else { return nil }
            return String(cString: buffer.ptr)
        }
    }

    /// Git stores commit times in whole seconds; make the next commit measurably newer.
    static func tick() { Thread.sleep(forTimeInterval: 1.1) }

    static let all: [TestCase] = [
        TestCase("firstSyncOfEmptyCloudRepositoryPushesToMain") { root in
            let cloud = try Cloud(root)
            let phone = try cloud.device("phone")
            try write(phone, "第一篇.md", "# 你好")
            let result = try sync(phone)

            try expect(result.pushed)
            try expectEqual(try read(cloud.device("laptop"), "第一篇.md"), "# 你好")
            try expectEqual(try log(phone), ["新建：第一篇"])
        },

        TestCase("pullsCloudChangesByFastForward") { root in
            let cloud = try Cloud(root)
            let a = try cloud.device("a")
            try write(a, "note.md", "v1")
            try sync(a)
            let b = try cloud.device("b")

            try write(a, "note.md", "v2")
            try sync(a)
            let result = try sync(b)

            try expect(result.pulled)
            try expect(!result.pushed)
            try expectEqual(try read(b, "note.md"), "v2")
            try expect(result.conflicts.isEmpty)
        },

        TestCase("mergesEditsToDifferentFiles") { root in
            let cloud = try Cloud(root)
            let a = try cloud.device("a")
            try write(a, "a.md", "a1")
            try write(a, "b.md", "b1")
            try sync(a)
            let b = try cloud.device("b")

            try write(a, "a.md", "a2")
            try sync(a)
            try write(b, "b.md", "b2")
            let result = try sync(b)

            try expect(result.pulled)
            try expect(result.pushed)
            try expect(result.conflicts.isEmpty)
            try expectEqual(try read(b, "a.md"), "a2")
            try expectEqual(try read(b, "b.md"), "b2")

            try sync(a)
            try expectEqual(try read(a, "b.md"), "b2")
            try expect(try log(b).first!.hasPrefix("同步：合并云端修改"))
        },

        TestCase("sameLineEditedOnBothSidesKeepsNewerLocalVersion") { root in
            let cloud = try Cloud(root)
            let a = try cloud.device("a")
            try write(a, "note.md", "base")
            try sync(a)
            let b = try cloud.device("b")

            try write(a, "note.md", "from a")
            try a.commitAll(author: author, device: "a")
            try sync(a)
            tick()
            try write(b, "note.md", "from b")
            try b.commitAll(author: author, device: "b")
            let result = try sync(b)

            try expectEqual(try read(b, "note.md"), "from b")
            try expectEqual(result.conflicts.count, 1)
            let conflict = result.conflicts[0]
            try expectEqual(conflict.kept, .local)
            try expectEqual(String(decoding: try b.readBlob(conflict.otherBlob!), as: UTF8.self), "from a")
            try expectEqual(b.conflicts(), [conflict])
            try expect(result.pushed)

            try sync(a)
            try expectEqual(try read(a, "note.md"), "from b")
        },

        TestCase("sameLineEditedOnBothSidesKeepsNewerCloudVersionAndCanSwitchBack") { root in
            let cloud = try Cloud(root)
            let a = try cloud.device("a")
            try write(a, "note.md", "base")
            try sync(a)
            let b = try cloud.device("b")

            try write(b, "note.md", "older from b")
            try b.commitAll(author: author, device: "b")
            tick()
            try write(a, "note.md", "newer from a")
            try a.commitAll(author: author, device: "a")
            try sync(a)
            let conflicts = try sync(b).conflicts
            try expectEqual(conflicts.count, 1)
            let conflict = conflicts[0]

            try expectEqual(conflict.kept, .remote)
            try expectEqual(try read(b, "note.md"), "newer from a")

            try b.useOtherVersion(conflict, author: author, device: "b")
            try expectEqual(try read(b, "note.md"), "older from b")
            try expect(b.conflicts().isEmpty)
            try sync(b)
            try sync(a)
            try expectEqual(try read(a, "note.md"), "older from b")
        },

        TestCase("editWinsOverDeleteOnTheOtherSide") { root in
            let cloud = try Cloud(root)
            let a = try cloud.device("a")
            try write(a, "note.md", "base")
            try sync(a)
            let b = try cloud.device("b")

            try FileManager.default.removeItem(at: a.workTree.appendingPathComponent("note.md"))
            try sync(a)
            try write(b, "note.md", "edited")
            let result = try sync(b)

            try expectEqual(try read(b, "note.md"), "edited")
            try expectEqual(result.conflicts.count, 1)
            try expect(result.conflicts[0].otherBlob == nil)
            try sync(a)
            try expectEqual(try read(a, "note.md"), "edited")
        },

        TestCase("respectsGitignoreAndLeavesItUntouched") { root in
            let cloud = try Cloud(root)
            let a = try cloud.device("a")
            try write(a, ".gitignore", "secret.txt\n")
            try write(a, "note.md", "hi")
            try sync(a)
            try write(a, "secret.txt", "do not upload")
            try sync(a)

            let b = try cloud.device("b")
            try expect(!FileManager.default.fileExists(atPath: b.workTree.appendingPathComponent("secret.txt").path))
            try expectEqual(try read(b, ".gitignore"), "secret.txt\n")
            try expect(try !a.hasUnsyncedWork())
        },

        TestCase("historyAndRestore") { root in
            let cloud = try Cloud(root)
            let a = try cloud.device("a")
            try write(a, "dir/日记.md", "v1")
            try a.commitAll(author: author, device: "a")
            try write(a, "dir/日记.md", "v2")
            try a.commitAll(author: author, device: "a")

            let history = try a.history("dir/日记.md")
            try expectEqual(history.map(\.message), ["编辑：日记", "新建：日记"])
            try expectEqual(String(decoding: try a.read(at: history.last!.commit, path: "dir/日记.md")!, as: UTF8.self), "v1")

            try a.restore("dir/日记.md", commit: history.last!.commit, author: author, device: "a")
            try expectEqual(try read(a, "dir/日记.md"), "v1")
            try expectEqual(try log(a).first, "恢复历史版本：日记")
        },

        TestCase("recoversFromInterruptedMerge") { root in
            let cloud = try Cloud(root)
            let a = try cloud.device("a")
            try write(a, "note.md", "base")
            try sync(a)
            let b = try cloud.device("b")
            try write(a, "note.md", "a")
            try sync(a)
            try write(b, "note.md", "b")
            try b.commitAll(author: author, device: "b")
            // Simulate a crash in the middle of a conflicting merge.
            try withRepo(b) { repo in
                var remote: OpaquePointer?
                try Git2.check(git_remote_lookup(&remote, repo, "origin"))
                defer { git_remote_free(remote) }
                try Git2.check(git_remote_fetch(remote, nil, nil, nil))
                var theirs = git_oid()
                try Git2.check(git_reference_name_to_id(&theirs, repo, "refs/remotes/origin/main"))
                var annotated: OpaquePointer?
                try Git2.check(git_annotated_commit_lookup(&annotated, repo, &theirs))
                defer { git_annotated_commit_free(annotated) }
                var heads: [OpaquePointer?] = [annotated]
                try Git2.check(git_merge(repo, &heads, 1, nil, nil))
                try expectEqual(git_repository_state(repo), Int32(GIT_REPOSITORY_STATE_MERGE.rawValue))
            }

            try sync(b)
            try withRepo(b) { try expectEqual(git_repository_state($0), Int32(GIT_REPOSITORY_STATE_NONE.rawValue)) }
            try expect(try !b.hasUnsyncedWork())
        },

        TestCase("unsyncedWorkIsDetected") { root in
            let cloud = try Cloud(root)
            let a = try cloud.device("a")
            try expect(try !a.hasUnsyncedWork())
            try write(a, "note.md", "x")
            try expect(try a.hasUnsyncedWork())
            try a.commitAll(author: author, device: "a")
            try expect(try a.hasUnsyncedWork())
            try sync(a)
            try expect(try !a.hasUnsyncedWork())
            try expectEqual(try configString(a, "branch.main.remote"), "origin")
        },

        TestCase("describesChanges") { _ in
            try expectEqual(NotebookGit.describeChanges(added: ["a.md"], changed: [], removed: []), "新建：a")
            try expectEqual(NotebookGit.describeChanges(added: [], changed: ["x/b.md"], removed: []), "编辑：b")
            try expectEqual(NotebookGit.describeChanges(added: [], changed: [], removed: ["c.txt"]), "删除：c.txt")
            try expectEqual(NotebookGit.describeChanges(added: ["b.md"], changed: [], removed: ["a.md"]), "重命名：a → b")
            try expectEqual(
                NotebookGit.describeChanges(added: ["c.md", "d.md"], changed: ["a.md", "b.md"], removed: []),
                "更新 4 个文件：a、b、c 等"
            )
            try expect(NotebookGit.describeChanges(added: [], changed: [], removed: []) == nil)
        },

        TestCase("classifiesErrorsForPeople") { _ in
            func kind(_ message: String, code: Int32 = -1) -> SyncError.Kind {
                NotebookGit.classify(GitError(code: code, message: message)).kind
            }
            try expectEqual(kind("too many redirects or authentication replays"), .auth)
            try expectEqual(kind("unexpected http status code: 403"), .auth)
            try expectEqual(kind("x", code: GIT_EAUTH.rawValue), .auth)
            try expectEqual(kind("failed to resolve address for gitee.com: nodename nor servname provided"), .network)
            try expectEqual(kind("failed to connect to 10.0.0.1: Connection refused"), .network)
            try expectEqual(kind("unexpected http status code: 404"), .notFound)
            try expectEqual(kind("https://x/y.git: Repository not found"), .notFound)
            let certificate = NotebookGit.classify(GitError(code: GIT_ECERTIFICATE.rawValue, message: "the SSL certificate is invalid"))
            try expect(certificate.message.contains("安全证书"), certificate.message)
        },

        TestCase("trustsTheCertificatesOfMacOS") { _ in
            try expect(FileManager.default.fileExists(atPath: "/etc/ssl/cert.pem"))
            // Fails if the TLS library behind libgit2 stops accepting a certificate file.
            try expectEqual(gn_use_system_certificates(), 0)
        },
    ]
}

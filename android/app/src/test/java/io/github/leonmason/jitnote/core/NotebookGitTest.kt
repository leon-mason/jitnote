package io.github.leonmason.jitnote.core

import org.eclipse.jgit.api.Git
import org.eclipse.jgit.lib.Constants
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.BeforeClass
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.nio.file.Files

class NotebookGitTest {
    @get:Rule
    val tmp = TemporaryFolder()

    private val author = Author("Tester", "tester@example.com")
    private lateinit var remoteUrl: String

    @Before
    fun createRemote() {
        val dir = tmp.newFolder("cloud.git")
        Git.init().setBare(true).setInitialBranch("main").setDirectory(dir).call().close()
        remoteUrl = dir.absolutePath
    }

    private fun device(name: String) = NotebookGit.clone(remoteUrl, File(tmp.root, name), null)

    private fun NotebookGit.write(path: String, text: String) =
        File(workTree, path).apply { parentFile?.mkdirs() }.writeText(text)

    private fun NotebookGit.read(path: String) = File(workTree, path).readText()

    private fun NotebookGit.syncNow(name: String = "phone", choices: Map<String, Side> = emptyMap()) =
        sync(null, author, name, choices)

    /** Whether any version of [path] in this repository's history had exactly [text]. */
    private fun NotebookGit.historyHas(path: String, text: String) =
        history(path).any { v -> readAt(v.commit, path)?.let { String(it) } == text }

    private fun pending(path: String, local: String?, cloud: String?) =
        PendingConflict(path, local?.toByteArray(), cloud?.toByteArray())

    private fun NotebookGit.state() = Git.open(workTree).use { it.repository.repositoryState.name }

    /** Two devices that edited note.md differently; the cloud has a's edit and b has its own committed. */
    private fun divergedNote(): Pair<NotebookGit, NotebookGit> {
        val a = device("a")
        a.write("note.md", "base")
        a.syncNow()
        val b = device("b")
        a.write("note.md", "from a")
        a.syncNow()
        b.write("note.md", "from b")
        b.commitAll(author, "b")
        return a to b
    }

    private fun cloudNote(): String = device("probe-${System.nanoTime()}").read("note.md")

    private fun NotebookGit.log(): List<String> = Git.open(workTree).use { git ->
        git.log().call().map { it.shortMessage }
    }

    /** Git stores commit times in whole seconds; make the next commit measurably newer. */
    private fun tick() = Thread.sleep(1_100)

    @Test
    fun firstSyncOfEmptyCloudRepositoryPushesToMain() {
        val phone = device("phone")
        phone.write("第一篇.md", "# 你好")
        val result = phone.syncNow()

        assertTrue(result.pushed)
        Git.open(File(remoteUrl)).use { cloud ->
            assertNotNull(cloud.repository.exactRef("refs/heads/main"))
        }
        assertEquals("# 你好", device("laptop").read("第一篇.md"))
        assertEquals(listOf("新建：第一篇"), phone.log())
    }

    @Test
    fun syncRecordsEveryChangeAsOneVersionAndNothingBeforeThat() {
        val a = device("a")
        a.write("a.md", "1")
        a.write("b.md", "2")
        a.write("dir/c.md", "3")
        assertTrue(a.hasUnsyncedWork())

        a.syncNow()

        val log = a.log()
        assertEquals(1, log.size)
        assertTrue(log.first(), log.first().startsWith("更新 3 个文件："))
        assertFalse(a.hasUnsyncedWork())
    }

    @Test
    fun pullsCloudChangesByFastForward() {
        val a = device("a")
        a.write("note.md", "v1")
        a.syncNow()
        val b = device("b")

        a.write("note.md", "v2")
        a.syncNow()
        val result = b.syncNow()

        assertTrue(result.pulled)
        assertFalse(result.pushed)
        assertEquals("v2", b.read("note.md"))
        assertTrue(result.pending.isEmpty())
    }

    @Test
    fun mergesEditsToDifferentFiles() {
        val a = device("a")
        a.write("a.md", "a1")
        a.write("b.md", "b1")
        a.syncNow()
        val b = device("b")

        a.write("a.md", "a2")
        a.syncNow()
        b.write("b.md", "b2")
        val result = b.syncNow()

        assertTrue(result.pulled)
        assertTrue(result.pushed)
        assertTrue(result.pending.isEmpty())
        assertEquals("a2", b.read("a.md"))
        assertEquals("b2", b.read("b.md"))

        a.syncNow()
        assertEquals("b2", a.read("b.md"))
        assertTrue(b.log().first().startsWith("同步：合并云端修改"))
    }

    @Test
    fun sameLineEditedOnBothSidesAsksAndTouchesNothing() {
        val (_, b) = divergedNote()

        val result = b.syncNow()

        assertEquals(listOf(pending("note.md", "from b", "from a")), result.pending)
        assertFalse(result.pushed || result.pulled)
        // The folder stays as it was while the user decides: no conflict markers, no merge under way.
        assertEquals("from b", b.read("note.md"))
        assertEquals("SAFE", b.state())
        assertFalse(syncMarker(b).exists())
        assertEquals("from a", cloudNote())
        assertTrue(b.hasUnsyncedWork())
    }

    @Test
    fun choosingTheLocalVersionKeepsItAndTheCloudVersionStaysInHistory() {
        val (a, b) = divergedNote()
        assertEquals(1, b.syncNow().pending.size)

        val result = b.syncNow(choices = mapOf("note.md" to Side.LOCAL))

        assertTrue(result.pending.isEmpty())
        assertEquals(1, result.resolved)
        assertTrue(result.pushed)
        assertEquals("from b", b.read("note.md"))
        a.syncNow()
        assertEquals("from b", a.read("note.md"))
        assertTrue("the version that lost must stay in history", a.historyHas("note.md", "from a"))
        assertTrue(b.log().first().startsWith("同步：合并云端修改（1 个文件两边都改了"))
    }

    @Test
    fun choosingTheCloudVersionTakesItAndTheLocalVersionStaysInHistory() {
        val (a, b) = divergedNote()

        val result = b.syncNow(choices = mapOf("note.md" to Side.REMOTE))

        assertTrue(result.pending.isEmpty() && result.pushed)
        assertEquals("from a", b.read("note.md"))
        assertTrue("the version that lost must stay in history", b.historyHas("note.md", "from b"))
        a.syncNow()
        assertEquals("from a", a.read("note.md"))
    }

    @Test
    fun cancellingLeavesTheQuestionForTheNextSync() {
        val (_, b) = divergedNote()

        assertEquals(1, b.syncNow().pending.size)
        // The user cancelled: nothing was kept from that attempt, so the next sync asks again.
        val again = b.syncNow()

        assertEquals(listOf("note.md"), again.pending.map { it.path })
        assertEquals("from a", cloudNote())
        assertEquals("from b", b.read("note.md"))
    }

    @Test
    fun onlyTheFilesBothSidesChangedAreAsked() {
        val a = device("a")
        a.write("note.md", "base")
        a.write("mine.md", "m0")
        a.write("theirs.md", "t0")
        a.syncNow()
        val b = device("b")
        a.write("note.md", "from a")
        a.write("theirs.md", "t1")
        a.syncNow()
        b.write("note.md", "from b")
        b.write("mine.md", "m1")

        assertEquals(listOf("note.md"), b.syncNow().pending.map { it.path })

        val done = b.syncNow(choices = mapOf("note.md" to Side.REMOTE, "unrelated.md" to Side.LOCAL))
        assertTrue(done.pending.isEmpty())
        assertEquals("from a", b.read("note.md"))
        assertEquals("m1", b.read("mine.md"))
        assertEquals("t1", b.read("theirs.md"))
    }

    @Test
    fun deletedOnOneSideAndEditedOnTheOtherAsksAndHonorsEitherChoice() {
        for (keepEdit in listOf(true, false)) {
            // One file name per round, so the rounds can share the cloud.
            val name = "note-$keepEdit.md"
            val a = device("a-$keepEdit")
            a.write(name, "base")
            a.syncNow()
            val b = device("b-$keepEdit")
            File(a.workTree, name).delete()
            a.syncNow()
            b.write(name, "edited")

            assertEquals(listOf(pending(name, "edited", null)), b.syncNow().pending)

            b.syncNow(choices = mapOf(name to if (keepEdit) Side.LOCAL else Side.REMOTE))
            a.syncNow()
            assertEquals(keepEdit, File(b.workTree, name).exists())
            assertEquals(keepEdit, File(a.workTree, name).exists())
            assertTrue("the edit must stay in history either way", b.historyHas(name, "edited"))
        }
    }

    @Test
    fun deletedLocallyAndEditedInTheCloudReportsTheDeletion() {
        val a = device("a")
        a.write("note.md", "base")
        a.syncNow()
        val b = device("b")
        a.write("note.md", "edited in the cloud")
        a.syncNow()
        File(b.workTree, "note.md").delete()

        assertEquals(listOf(pending("note.md", null, "edited in the cloud")), b.syncNow().pending)

        b.syncNow(choices = mapOf("note.md" to Side.LOCAL))
        assertFalse(File(b.workTree, "note.md").exists())
    }

    @Test
    fun removesConflictRecordsOfEarlierVersions() {
        val a = device("a")
        val legacy = File(a.workTree, ".git/jitnote/conflicts.json").apply {
            parentFile?.mkdirs()
            writeText("[]")
        }
        a.write("note.md", "x")

        a.syncNow()

        assertFalse(legacy.exists())
    }

    @Test
    fun respectsGitignoreAndLeavesItUntouched() {
        val a = device("a")
        a.write(".gitignore", "secret.txt\n")
        a.write("note.md", "hi")
        a.syncNow()
        a.write("secret.txt", "do not upload")
        a.syncNow()

        val b = device("b")
        assertFalse(File(b.workTree, "secret.txt").exists())
        assertEquals("secret.txt\n", b.read(".gitignore"))
        assertFalse(a.hasUnsyncedWork())
    }

    @Test
    fun historyAndRestore() {
        val a = device("a")
        a.write("dir/日记.md", "v1")
        a.commitAll(author, "a")
        a.write("dir/日记.md", "v2")
        a.commitAll(author, "a")

        val history = a.history("dir/日记.md")
        assertEquals(listOf("编辑：日记", "新建：日记"), history.map { it.message })
        assertEquals("v1", String(a.readAt(history.last().commit, "dir/日记.md")!!))

        a.restore("dir/日记.md", history.last().commit, author, "a")
        assertEquals("v1", a.read("dir/日记.md"))
        // Nothing new to keep, so restoring adds no version; the restored text goes in with the next sync.
        assertEquals(listOf("编辑：日记", "新建：日记"), a.log())
        assertTrue(a.hasLocalChanges())
        a.syncNow()
        assertEquals("编辑：日记", a.log().first())
    }

    @Test
    fun restoreKeepsTheTextThatWasNotSavedYet() {
        val a = device("a")
        a.write("日记.md", "v1")
        a.commitAll(author, "a")
        a.write("日记.md", "v2, never committed")
        a.write("other.md", "unrelated")
        val first = a.history("日记.md").last().commit

        a.restore("日记.md", first, author, "a")

        assertEquals("v1", a.read("日记.md"))
        val kept = a.history("日记.md").first()
        assertEquals("v2, never committed", String(a.readAt(kept.commit, "日记.md")!!))
        // Only the restored file was recorded.
        assertNull(a.readAt(kept.commit, "other.md"))
    }

    @Test
    fun commitPathsRecordsOnlyThosePaths() {
        val a = device("a")
        a.write("dir/x.md", "x1")
        a.write("keep.md", "k1")
        a.commitAll(author, "a")
        a.write("dir/x.md", "x2")
        a.write("dir/new.md", "new")
        a.write("dir/secret.txt", "ignored")
        a.write(".gitignore", "secret.txt\n")
        a.write("keep.md", "k2")
        a.write("a[1].md", "glob characters in a name")
        a.write("a1.md", "must not be matched by that glob")

        assertTrue(a.commitPaths(listOf("dir", "a[1].md"), author, "a"))

        val head = a.history("dir/x.md").first().commit
        assertEquals("x2", String(a.readAt(head, "dir/x.md")!!))
        assertEquals("new", String(a.readAt(head, "dir/new.md")!!))
        assertEquals("glob characters in a name", String(a.readAt(head, "a[1].md")!!))
        assertNull(a.readAt(head, "dir/secret.txt"))
        assertNull(a.readAt(head, "a1.md"))
        assertEquals("k1", String(a.readAt(head, "keep.md")!!))
        assertTrue("the other changes stay uncommitted", a.hasLocalChanges())
        assertFalse("nothing new under dir", a.commitPaths(listOf("dir"), author, "a"))
    }

    @Test
    fun commitPathsRecordsADeletedFolder() {
        val a = device("a")
        a.write("dir/x.md", "x1")
        a.commitAll(author, "a")
        File(a.workTree, "dir").deleteRecursively()

        assertTrue(a.commitPaths(listOf("dir"), author, "a"))

        assertEquals("删除：x", a.log().first())
        val history = a.history("dir/x.md")
        assertNull(a.readAt(history.first().commit, "dir/x.md"))
        assertEquals("x1", String(a.readAt(history.last().commit, "dir/x.md")!!))
    }

    @Test
    fun deletingANoteThatWasNeverCommittedKeepsItsText() {
        val a = device("a")
        a.write("base.md", "b")
        a.commitAll(author, "a")
        a.write("draft.md", "written a minute ago")

        // What the app does before deleting: keep a version of just this note.
        a.commitPaths(listOf("draft.md"), author, "a")
        File(a.workTree, "draft.md").delete()
        a.syncNow()

        val history = a.history("draft.md")
        assertEquals(listOf("删除：draft", "新建：draft"), history.map { it.message })
        assertEquals("written a minute ago", String(a.readAt(history.last().commit, "draft.md")!!))
    }

    /**
     * Two devices that both edited note.md; returns the one left in the middle of merging the other's edit,
     * the way a crash (or another tool such as an AI's Git client) leaves it.
     */
    private fun startConflictingMerge(): NotebookGit {
        val a = device("a")
        a.write("note.md", "base")
        a.syncNow()
        val b = device("b")
        a.write("note.md", "a")
        a.syncNow()
        b.write("note.md", "b")
        b.commitAll(author, "b")
        Git.open(b.workTree).use { git ->
            git.fetch().call()
            git.merge().include(git.repository.resolve("refs/remotes/origin/main")).call()
            assertEquals("MERGING", git.repository.repositoryState.name)
        }
        return b
    }

    private fun syncMarker(git: NotebookGit) = File(git.workTree, ".git/${NotebookGit.SYNC_MARKER}")

    private fun NotebookGit.syncFailure(): SyncException? =
        try {
            syncNow()
            null
        } catch (e: SyncException) {
            e
        }

    private fun NotebookGit.configValue(name: String): String? =
        Git.open(workTree).use { it.repository.config.getString("user", null, name) }

    private fun NotebookGit.setConfig(name: String, value: String) = Git.open(workTree).use {
        it.repository.config.setString("user", null, name, value)
        it.repository.config.save()
    }

    @Test
    fun recoversFromInterruptedMerge() {
        val b = startConflictingMerge()
        // A sync of this app that died leaves its marker behind; that is what makes the merge ours to abort.
        syncMarker(b).apply {
            parentFile?.mkdirs()
            writeText("")
        }

        // The merge is aborted. The two edits really do clash, so the sync then asks about them.
        assertEquals(listOf("note.md"), b.syncNow().pending.map { it.path })
        assertEquals("SAFE", b.state())
        assertFalse(syncMarker(b).exists())

        b.syncNow(choices = mapOf("note.md" to Side.LOCAL))
        assertFalse(b.hasUnsyncedWork())
    }

    @Test
    fun leavesAnotherToolsUnfinishedMergeAlone() {
        val b = startConflictingMerge()
        val conflicted = b.read("note.md")

        val failure = b.syncFailure()

        assertNotNull("sync should refuse to touch a merge it did not start", failure)
        assertTrue(failure!!.message!!.contains("合并"))
        Git.open(b.workTree).use { assertEquals("MERGING", it.repository.repositoryState.name) }
        assertEquals(conflicted, b.read("note.md"))
        assertFalse(syncMarker(b).exists())
    }

    @Test
    fun waitsForAnotherProgramsIndexLock() {
        val a = device("a")
        a.write("note.md", "x")
        val lock = File(a.workTree, ".git/index.lock").apply { writeText("") }

        val saved = NotebookGit.indexLockWaitMillis
        try {
            NotebookGit.indexLockWaitMillis = 300
            val failure = a.syncFailure()
            assertNotNull("a lock that never goes away should stop the sync", failure)
            assertTrue(failure!!.message!!.contains("稍后再同步"))
            assertTrue("the other program's lock must stay", lock.exists())
            assertTrue("nothing may be committed while the lock is held", a.hasLocalChanges())

            // The other program finishes while the sync is waiting.
            NotebookGit.indexLockWaitMillis = 5_000
            Thread {
                Thread.sleep(400)
                lock.delete()
            }.start()
            assertTrue(a.syncNow().pushed)
        } finally {
            NotebookGit.indexLockWaitMillis = saved
        }
    }

    @Test
    fun pushesACommitMadeByAnotherToolAsIs() {
        val a = device("a")
        a.write("note.md", "written by an AI")
        a.commitAll(Author("AI", "ai@example.com"), "ai")
        val theirs = a.history("note.md").first().commit

        val result = a.syncNow()

        assertTrue(result.pushed)
        assertEquals(listOf("新建：note"), a.log())
        assertEquals(listOf(theirs), device("c").history("note.md").map { it.commit })
    }

    @Test
    fun mergesACommitMadeByAnotherToolWithoutRewritingIt() {
        val a = device("a")
        val b = device("b")
        a.write("ai.md", "from the AI")
        a.commitAll(Author("AI", "ai@example.com"), "ai")
        val theirs = a.history("ai.md").first().commit
        b.write("other.md", "from the cloud")
        b.syncNow()

        val result = a.syncNow()

        assertTrue(result.pulled && result.pushed)
        assertEquals("from the cloud", a.read("other.md"))
        // Merge, never rebase: the other tool's commit keeps its identity and reaches the cloud untouched.
        assertEquals(listOf(theirs), device("c").history("ai.md").map { it.commit })
    }

    @Test
    fun keepsAnIdentityThatIsAlreadyConfigured() {
        val a = device("a")
        a.setConfig("name", "Me")
        a.setConfig("email", "me@example.org")
        a.write("note.md", "x")
        a.syncNow()

        assertEquals("Me", a.configValue("name"))
        assertEquals("me@example.org", a.configValue("email"))
    }

    @Test
    fun writesAnIdentityForOtherToolsWhenNoneIsConfigured() {
        val a = device("a")
        assertNull(a.configValue("name"))
        a.write("note.md", "x")
        a.syncNow()

        assertEquals("Tester", a.configValue("name"))
        assertEquals("tester@example.com", a.configValue("email"))
    }

    @Test
    fun unsyncedWorkIsDetected() {
        val a = device("a")
        assertFalse(a.hasUnsyncedWork())
        a.write("note.md", "x")
        assertTrue(a.hasUnsyncedWork())
        a.commitAll(author, "a")
        assertTrue(a.hasUnsyncedWork())
        a.syncNow()
        assertFalse(a.hasUnsyncedWork())
        Git.open(a.workTree).use { assertEquals("main", it.repository.branch) }
        Git.open(a.workTree).use {
            assertEquals("origin", it.repository.config.getString("branch", "main", "remote"))
            assertNotNull(it.repository.exactRef(Constants.R_REMOTES + "origin/main"))
        }
    }

    @Test
    fun describesChanges() {
        assertEquals("新建：a", NotebookGit.describeChanges(setOf("a.md"), emptySet(), emptySet()))
        assertEquals("编辑：b", NotebookGit.describeChanges(emptySet(), setOf("x/b.md"), emptySet()))
        assertEquals("删除：c.txt", NotebookGit.describeChanges(emptySet(), emptySet(), setOf("c.txt")))
        assertEquals("重命名：a → b", NotebookGit.describeChanges(setOf("b.md"), emptySet(), setOf("a.md")))
        assertEquals("重命名：a → b", NotebookGit.describeChanges(setOf("x/b.md"), emptySet(), setOf("x/a.md")))
        assertEquals("移动：读书笔记 → 工作/项目", NotebookGit.describeChanges(setOf("工作/项目/读书笔记.md"), emptySet(), setOf("读书笔记.md")))
        assertEquals("移动：读书笔记 → 根目录", NotebookGit.describeChanges(setOf("读书笔记.md"), emptySet(), setOf("工作/读书笔记.md")))
        assertEquals("重命名：a → 工作/b", NotebookGit.describeChanges(setOf("工作/b.md"), emptySet(), setOf("a.md")))
        assertEquals("重命名：a → b", NotebookGit.describeChanges(setOf("b.md"), emptySet(), setOf("x/a.md")))
        assertEquals(
            "移动：会议记录 → 工作",
            NotebookGit.describeChanges(
                setOf("工作/会议记录/a.md", "工作/会议记录/img/b.png"),
                emptySet(),
                setOf("会议记录/a.md", "会议记录/img/b.png"),
            ),
        )
        assertEquals(
            "移动：会议记录 → 根目录",
            NotebookGit.describeChanges(setOf("会议记录/a.md", "会议记录/b.md"), emptySet(), setOf("工作/会议记录/a.md", "工作/会议记录/b.md")),
        )
        // A folder renamed in place, files moved out of a folder one by one, or a move with edits: not a folder move.
        assertEquals("更新 4 个文件：a、b", NotebookGit.describeChanges(setOf("y/a.md", "y/b.md"), emptySet(), setOf("x/a.md", "x/b.md")))
        assertEquals("更新 4 个文件：a、b", NotebookGit.describeChanges(setOf("工作/a.md", "工作/b.md"), emptySet(), setOf("a.md", "b.md")))
        assertEquals("更新 3 个文件：c、a", NotebookGit.describeChanges(setOf("新/a.md"), setOf("c.md"), setOf("旧/a.md")))
        assertEquals(
            "更新 4 个文件：a、b、c 等",
            NotebookGit.describeChanges(setOf("c.md", "d.md"), setOf("a.md", "b.md"), emptySet()),
        )
        assertNull(NotebookGit.describeChanges(emptySet(), emptySet(), emptySet()))
    }

    @Test
    fun classifiesErrorsForPeople() {
        fun kind(message: String) = NotebookGit.classify(RuntimeException(message)).kind
        assertEquals(SyncException.Kind.AUTH, kind("https://gitee.com/a/b.git: not authorized"))
        assertEquals(SyncException.Kind.AUTH, kind("git-receive-pack not permitted on 'https://x/y.git/'"))
        assertEquals(
            SyncException.Kind.NETWORK,
            kind("Cleartext HTTP traffic to 10.0.2.2 not permitted"),
        )
        assertEquals(SyncException.Kind.NOT_FOUND, kind("https://x/y.git: Repository not found"))
        assertEquals(
            SyncException.Kind.NETWORK,
            NotebookGit.classify(RuntimeException("x", java.net.UnknownHostException("gitee.com"))).kind,
        )
    }

    companion object {
        @BeforeClass
        @JvmStatic
        fun isolateGit() = GitEnvironment.install(Files.createTempDirectory("jgit-config").toFile())
    }
}

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

    private fun NotebookGit.syncNow(name: String = "phone") = sync(null, author, name)

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
        assertTrue(result.conflicts.isEmpty())
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
        assertTrue(result.conflicts.isEmpty())
        assertEquals("a2", b.read("a.md"))
        assertEquals("b2", b.read("b.md"))

        a.syncNow()
        assertEquals("b2", a.read("b.md"))
        assertTrue(b.log().first().startsWith("同步：合并云端修改"))
    }

    @Test
    fun sameLineEditedOnBothSidesKeepsNewerLocalVersion() {
        val a = device("a")
        a.write("note.md", "base")
        a.syncNow()
        val b = device("b")

        a.write("note.md", "from a")
        a.commitAll(author, "a")
        a.syncNow()
        tick()
        b.write("note.md", "from b")
        b.commitAll(author, "b")
        val result = b.syncNow()

        assertEquals("from b", b.read("note.md"))
        val conflict = result.conflicts.single()
        assertEquals(Side.LOCAL, conflict.kept)
        assertEquals("from a", String(b.readBlob(conflict.otherBlob!!)))
        assertEquals(listOf(conflict), b.conflicts())
        assertTrue(result.pushed)

        a.syncNow()
        assertEquals("from b", a.read("note.md"))
    }

    @Test
    fun sameLineEditedOnBothSidesKeepsNewerCloudVersionAndCanSwitchBack() {
        val a = device("a")
        a.write("note.md", "base")
        a.syncNow()
        val b = device("b")

        b.write("note.md", "older from b")
        b.commitAll(author, "b")
        tick()
        a.write("note.md", "newer from a")
        a.commitAll(author, "a")
        a.syncNow()
        val conflict = b.syncNow().conflicts.single()

        assertEquals(Side.REMOTE, conflict.kept)
        assertEquals("newer from a", b.read("note.md"))

        b.useOtherVersion(conflict, author, "b")
        assertEquals("older from b", b.read("note.md"))
        assertTrue(b.conflicts().isEmpty())
        b.syncNow()
        a.syncNow()
        assertEquals("older from b", a.read("note.md"))
    }

    @Test
    fun editWinsOverDeleteOnTheOtherSide() {
        val a = device("a")
        a.write("note.md", "base")
        a.syncNow()
        val b = device("b")

        File(a.workTree, "note.md").delete()
        a.syncNow()
        b.write("note.md", "edited")
        val result = b.syncNow()

        assertEquals("edited", b.read("note.md"))
        assertNull(result.conflicts.single().otherBlob)
        a.syncNow()
        assertEquals("edited", a.read("note.md"))
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
        assertEquals("恢复历史版本：日记", a.log().first())
    }

    @Test
    fun recoversFromInterruptedMerge() {
        val a = device("a")
        a.write("note.md", "base")
        a.syncNow()
        val b = device("b")
        a.write("note.md", "a")
        a.syncNow()
        b.write("note.md", "b")
        b.commitAll(author, "b")
        // Simulate a crash in the middle of a conflicting merge.
        Git.open(b.workTree).use { git ->
            git.fetch().call()
            git.merge().include(git.repository.resolve("refs/remotes/origin/main")).call()
            assertEquals("MERGING", git.repository.repositoryState.name)
        }

        b.syncNow()
        Git.open(b.workTree).use { assertEquals("SAFE", it.repository.repositoryState.name) }
        assertFalse(b.hasUnsyncedWork())
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

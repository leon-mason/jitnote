package io.github.leonmason.jitnote.data

import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class BrokenImageCheckTest {
    @get:Rule
    val tmp = TemporaryFolder()

    private lateinit var root: File

    @Before
    fun notebook() {
        root = tmp.newFolder("notebook")
        mapOf(
            "笔记/a.md" to "![封面](img/a.png)",
            "笔记/img/a.png" to "x",
            "日志/b.md" to "![](../笔记/img/a.png)",
            "c.md" to "![](/笔记/img/a.png)",
            "d.md" to "![](https://example.com/x.png) ![[a.png]] ![](missing.png)",
            "e.md" to "![](my%20photo.png) ![](<my photo.png>)",
            "my photo.png" to "x",
            "g.md" to "```\n![](root.png)\n```",
            "root.png" to "x",
        ).forEach { (path, text) -> File(root, path).apply { parentFile.mkdirs() }.writeText(text) }
    }

    private fun broken(source: String, target: String) = BrokenImageCheck.notes(root, source, target)

    @Test
    fun aNoteMovedAwayFromItsImages() {
        assertEquals(listOf("笔记/a.md"), broken("笔记/a.md", "工作"))
    }

    @Test
    fun aFolderMovedTogetherWithItsImages() {
        // Only the notes that point into the folder from outside lose their image.
        assertEquals(listOf("c.md", "日志/b.md"), broken("笔记", "工作"))
        assertEquals(emptyList<String>(), broken("笔记", ""))
    }

    @Test
    fun anImageMovedAwayFromItsNotes() {
        assertEquals(listOf("c.md", "日志/b.md", "笔记/a.md"), broken("笔记/img/a.png", ""))
        assertEquals(listOf("e.md"), broken("my photo.png", "工作"))
    }

    @Test
    fun parentFolderReferencesAreFollowed() {
        assertEquals(emptyList<String>(), broken("日志/b.md", "工作"))
        assertEquals(emptyList<String>(), broken("日志/b.md", "笔记"))
        assertEquals(listOf("日志/b.md"), broken("日志/b.md", "工作/深"))
        assertEquals(emptyList<String>(), broken("c.md", "笔记"))
    }

    @Test
    fun encodedAndBracketedPathsCountOncePerNote() {
        assertEquals(listOf("e.md"), broken("e.md", "工作"))
    }

    @Test
    fun onlyReferencesThatWorkedBeforeCount() {
        assertEquals(emptyList<String>(), broken("d.md", "工作"))
        assertEquals(emptyList<String>(), broken("root.png", "工作"))
    }

    @Test
    fun encodedPathsKeepCharactersOutsideTheBasicPlane() {
        File(root, "猫 \uD83D\uDC31.png").writeText("x")
        File(root, "h.md").writeText("![](%E7%8C%AB%20\uD83D\uDC31.png)")
        assertEquals(listOf("h.md"), broken("h.md", "工作"))
    }

    @Test
    fun anUnreadableNoteIsSkipped() {
        File(root, "坏.md").apply { writeText("![](x.png)") }.setReadable(false)
        assertEquals(listOf("笔记/a.md"), broken("笔记/a.md", "工作"))
        assertEquals(listOf("c.md", "日志/b.md", "笔记/a.md"), broken("笔记/img/a.png", ""))
    }

    @Test
    fun readsOnly() {
        val before = root.walkTopDown().filter { it.isFile }.associate { it.path to it.readText() }
        broken("笔记", "工作")
        assertEquals(before, root.walkTopDown().filter { it.isFile }.associate { it.path to it.readText() })
    }
}

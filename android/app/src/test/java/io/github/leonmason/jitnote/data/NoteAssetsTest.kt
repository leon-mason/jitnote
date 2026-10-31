package io.github.leonmason.jitnote.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class NoteAssetsTest {
    @get:Rule
    val tmp = TemporaryFolder()

    private lateinit var assets: NoteAssets

    @Before
    fun notebook() {
        val root = tmp.newFolder("notebook")
        listOf(
            "日记/assets/my photo.png",
            "附件/封面.png",
            "附件/深/封面.png",
            "图库/2026/封面.png",
            ".git/objects/封面.png",
        ).forEach { File(root, it).apply { parentFile.mkdirs() }.writeText("x") }
        File(tmp.root, "outside.png").writeText("x")
        assets = NoteAssets(root)
    }

    @Test
    fun relativeToTheNote() {
        assertEquals("日记/assets/my photo.png", assets.resolve("日记", "assets/my photo.png"))
        assertEquals("日记/assets/my photo.png", assets.resolve("日记", "./assets/my photo.png"))
    }

    @Test
    fun relativeToTheNotebookRoot() {
        assertEquals("附件/封面.png", assets.resolve("日记", "附件/封面.png"))
        assertEquals("附件/封面.png", assets.resolve("日记", "/附件/封面.png"))
    }

    @Test
    fun byNameAnywhereShortestPathFirst() {
        assertEquals("附件/封面.png", assets.resolve("日记", "封面.png"))
        assertEquals("图库/2026/封面.png", assets.resolve("", "2026/封面.png"))
        assertEquals("日记/assets/my photo.png", assets.resolve("", "MY PHOTO.png"))
    }

    @Test
    fun neverLeavesTheNotebookOrReadsGitInternals() {
        assertNull(assets.resolve("日记", "../../outside.png"))
        assertNull(assets.resolve("", "outside.png"))
        assertNull(assets.resolve("", "objects/封面.png"))
        assertNull(assets.resolve("", "https://example.com/a.png"))
        assertNull(assets.resolve("", "missing.png"))
    }
}

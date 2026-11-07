package io.github.leonmason.jitnote.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class NoteFilesMoveTest {
    @get:Rule
    val tmp = TemporaryFolder()

    private lateinit var root: File

    private fun write(path: String, text: String = "x") = File(root, path).apply { parentFile.mkdirs() }.writeText(text)

    @Before
    fun notebook() {
        root = tmp.newFolder("notebook")
    }

    @Test
    fun movesAFileIntoAFolder() {
        write("a.md", "内容")
        File(root, "工作").mkdirs()
        val moved = NoteFiles.move(File(root, "a.md"), File(root, "工作"))
        assertEquals("工作/a.md", NoteFiles.relativePath(root, moved))
        assertEquals("内容", moved.readText())
        assertFalse(File(root, "a.md").exists())
    }

    @Test
    fun movesAFolderWithEverythingInside() {
        write("会议/2026/x.md", "纪要")
        File(root, "工作").mkdirs()
        NoteFiles.move(File(root, "会议"), File(root, "工作"))
        assertEquals("纪要", File(root, "工作/会议/2026/x.md").readText())
        assertFalse(File(root, "会议").exists())
    }

    @Test
    fun movesToTheNotebookRoot() {
        write("工作/a.md")
        NoteFiles.move(File(root, "工作/a.md"), root)
        assertTrue(File(root, "a.md").exists())
    }

    @Test
    fun refusesWhenTheNameIsTaken() {
        write("a.md", "新")
        write("工作/a.md", "旧")
        val error = assertThrows(IllegalArgumentException::class.java) { NoteFiles.move(File(root, "a.md"), File(root, "工作")) }
        assertEquals("目标文件夹里已有同名文件", error.message)
        assertEquals("新", File(root, "a.md").readText())
        assertEquals("旧", File(root, "工作/a.md").readText())
    }

    @Test
    fun aFolderCannotGoIntoItself() {
        write("会议/2026/x.md")
        assertThrows(IllegalArgumentException::class.java) { NoteFiles.move(File(root, "会议"), File(root, "会议/2026")) }
        assertThrows(IllegalArgumentException::class.java) { NoteFiles.move(File(root, "会议"), File(root, "会议")) }
        assertTrue(File(root, "会议/2026/x.md").exists())
    }

    @Test
    fun movingToWhereItIsChangesNothing() {
        write("a.md", "内容")
        val same = NoteFiles.move(File(root, "a.md"), root)
        assertEquals("内容", same.readText())
    }
}

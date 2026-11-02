package io.github.leonmason.jitnote.data

import org.junit.Assert.assertEquals
import org.junit.Test

class FileTreeTest {
    private fun file(path: String) = NoteIndex.Entry(path, path.substringAfterLast('/'), false, emptyList(), 0, 0L)
    private fun folder(path: String, vararg children: NoteIndex.Entry) =
        NoteIndex.Entry(path, path.substringAfterLast('/'), true, children.toList(), 0, 0L)

    private val tree = listOf(
        folder("会议", folder("会议/2026", file("会议/2026/周会.md"))),
        folder("会议记录"),
        file("a.md"),
    )

    @Test
    fun visibleRowsOnlyShowOpenFolders() {
        val rows = FileTree.visibleRows(tree, setOf("会议"))
        assertEquals(listOf("会议", "2026", "会议记录", "a.md"), rows.map { it.entry.name })
        assertEquals(listOf(0, 1, 0, 0), rows.map { it.depth })
    }

    @Test
    fun visibleRowsIgnoreStaleExpandedPaths() {
        val rows = FileTree.visibleRows(tree, setOf("不存在/的"))
        assertEquals(listOf("会议", "会议记录", "a.md"), rows.map { it.entry.name })
    }

    @Test
    fun currentFolderOfAFolderIsItself() {
        assertEquals("会议/2026", FileTree.currentFolder(tree, "会议/2026"))
    }

    @Test
    fun currentFolderOfAFileIsItsParent() {
        assertEquals("会议/2026", FileTree.currentFolder(tree, "会议/2026/周会.md"))
        assertEquals("", FileTree.currentFolder(tree, "a.md"))
    }

    @Test
    fun currentFolderFallsBackToRootWhenMissing() {
        assertEquals("", FileTree.currentFolder(tree, "已删除/x.md"))
        assertEquals("", FileTree.currentFolder(tree, ""))
    }

    @Test
    fun parentAndAncestors() {
        assertEquals("会议", FileTree.parent("会议/2026"))
        assertEquals("", FileTree.parent("会议"))
        assertEquals(setOf("会议", "会议/2026"), FileTree.ancestors("会议/2026/周会.md"))
    }

    @Test
    fun renameMovesTheFolderAndWhatIsInside() {
        assertEquals(setOf("工作", "工作/2026", "b"), FileTree.renamed(setOf("会议", "会议/2026", "b"), "会议", "工作"))
    }

    @Test
    fun renameDoesNotTouchSimilarNames() {
        assertEquals(setOf("工作", "会议记录"), FileTree.renamed(setOf("会议", "会议记录"), "会议", "工作"))
        assertEquals("会议记录/x.md", FileTree.moved("会议记录/x.md", "会议", "工作"))
    }

    @Test
    fun removeDropsTheFolderAndWhatIsInside() {
        assertEquals(setOf("会议记录"), FileTree.removed(setOf("会议", "会议/2026", "会议记录"), "会议"))
    }
}

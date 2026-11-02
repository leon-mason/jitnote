package io.github.leonmason.jitnote.data

import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class NoteIndexTest {
    @get:Rule
    val tmp = TemporaryFolder()

    private fun write(path: String, text: String = "", modified: Long = 0L): File {
        val file = File(tmp.root, path)
        file.parentFile!!.mkdirs()
        file.writeText(text)
        if (modified > 0) file.setLastModified(modified)
        return file
    }

    @Test
    fun buildsTheFileTreeLikeObsidian() {
        write("b.md")
        write("A.txt")
        write("会议/2026/x.md")
        write("会议/2026/y.md")
        write("会议/2025/z.md")
        write("会议/议程.md")
        write("技术/安卓/发布/r.md")
        write("附件/cat.png")
        File(tmp.root, "空文件夹").mkdirs()
        write(".obsidian/w.md")

        val tree = NoteIndex.tree(tmp.root)
        // Folders first, then files with their extensions; Chinese names sort by pinyin: fu, hui, ji, kong.
        assertEquals(listOf("附件", "会议", "技术", "空文件夹", "A.txt", "b.md"), tree.map { it.name })
        val meetings = tree[1]
        assertEquals(4, meetings.noteCount)
        assertEquals(listOf("2025", "2026", "议程.md"), meetings.children.map { it.name })
        assertEquals("会议/2026", meetings.children[1].path)
        assertEquals(2, meetings.children[1].noteCount)
        assertEquals("会议/议程.md", meetings.children[2].path)
        assertEquals(false, meetings.children[2].isFolder)
        assertEquals(listOf("cat.png"), tree[0].children.map { it.name })
        assertEquals(0, tree[0].noteCount)
        assertEquals(listOf("r.md"), tree[2].children[0].children[0].children.map { it.name })
    }

    @Test
    fun hiddenFilesOnlyWhenAskedAndNeverGit() {
        write("a.md")
        write(".obsidian/templates/模板.md")
        write(".git/notes.md")

        assertEquals(listOf("a.md"), NoteIndex.tree(tmp.root).map { it.name })

        val tree = NoteIndex.tree(tmp.root, showHidden = true)
        assertEquals(listOf(".obsidian", "a.md"), tree.map { it.name })
        assertEquals(1, tree[0].noteCount)
    }

    @Test
    fun treeSortsByNameBothWays() {
        write("b.md"); write("a.md"); write("乙/x.md"); write("甲/x.md")
        assertEquals(listOf("甲", "乙", "a.md", "b.md"), NoteIndex.tree(tmp.root, NoteSort.TITLE_ASC).map { it.name })
        assertEquals(listOf("乙", "甲", "b.md", "a.md"), NoteIndex.tree(tmp.root, NoteSort.TITLE_DESC).map { it.name })
    }

    @Test
    fun treeSortsFilesByMinuteAndKeepsFoldersByName() {
        write("a.md", modified = 60_000_000); write("b.md", modified = 180_000_000); write("c.md", modified = 120_000_000)
        write("乙/x.md"); write("甲/x.md")
        assertEquals(listOf("甲", "乙", "b.md", "c.md", "a.md"), NoteIndex.tree(tmp.root, NoteSort.MODIFIED_DESC).map { it.name })
        assertEquals(listOf("甲", "乙", "a.md", "c.md", "b.md"), NoteIndex.tree(tmp.root, NoteSort.MODIFIED_ASC).map { it.name })
    }

    @Test
    fun treeBreaksTiesInTheSameMinuteByName() {
        write("b.md", modified = 60_000_000); write("a.md", modified = 60_030_000)
        assertEquals(listOf("a.md", "b.md"), NoteIndex.tree(tmp.root, NoteSort.MODIFIED_DESC).map { it.name })
    }

    @Test
    fun treeOrdersALargeFolderBySnapshotAndKeepsEachModifiedTime() {
        // Distinct minutes, written in an order unrelated to the times, with folders mixed in.
        val minutes = (1..300).map { (it * 37) % 301 + 1 }
        minutes.forEachIndexed { i, m -> write("n$i.md", modified = m * 60_000L + 1_000_000_000L) }
        write("乙/x.md"); write("甲/x.md")

        val newestFirst = NoteIndex.tree(tmp.root, NoteSort.MODIFIED_DESC)
        assertEquals(listOf("甲", "乙"), newestFirst.take(2).map { it.name })
        val files = newestFirst.drop(2)
        assertEquals(300, files.size)
        assertEquals(files.map { it.modified }.sortedDescending(), files.map { it.modified })
        assertEquals(files.map { File(tmp.root, it.path).lastModified() }, files.map { it.modified })

        val oldestFirst = NoteIndex.tree(tmp.root, NoteSort.MODIFIED_ASC).drop(2)
        assertEquals(files.reversed().map { it.name }, oldestFirst.map { it.name })
    }
}

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
    fun listsEveryNoteInEveryFolderButNotOtherFiles() {
        write("读书清单.md")
        write("会议/2026/周会.md")
        write("技术/安卓/发布.markdown")
        write("技术/随手记.txt")
        write("附件/cat.png")
        write(".obsidian/workspace.md")
        write(".git/HEAD")

        val notes = NoteIndex.notes(tmp.root, NoteSort.TITLE_ASC)
        assertEquals(listOf("发布", "周会", "读书清单", "随手记"), notes.map { it.title }.sorted())
        assertEquals("会议/2026", notes.first { it.title == "周会" }.folder)
        assertEquals("", notes.first { it.title == "读书清单" }.folder)
        assertEquals("技术/安卓/发布.markdown", notes.first { it.title == "发布" }.path)
    }

    @Test
    fun filtersByFolderIncludingSubfolders() {
        write("a.md")
        write("技术/b.md")
        write("技术/安卓/c.md")
        write("技术员/d.md")

        assertEquals(listOf("b", "c"), NoteIndex.notes(tmp.root, NoteSort.TITLE_ASC, folder = "技术").map { it.title })
        assertEquals(listOf("c"), NoteIndex.notes(tmp.root, NoteSort.TITLE_ASC, folder = "技术/安卓").map { it.title })
    }

    @Test
    fun sortsByTimeOrTitle() {
        write("b.md", modified = 3_000_000)
        write("a.md", modified = 1_000_000)
        write("C.md", modified = 2_000_000)

        assertEquals(listOf("b", "C", "a"), NoteIndex.notes(tmp.root, NoteSort.MODIFIED_DESC).map { it.title })
        assertEquals(listOf("a", "C", "b"), NoteIndex.notes(tmp.root, NoteSort.MODIFIED_ASC).map { it.title })
        assertEquals(listOf("a", "b", "C"), NoteIndex.notes(tmp.root, NoteSort.TITLE_ASC).map { it.title })
        assertEquals(listOf("C", "b", "a"), NoteIndex.notes(tmp.root, NoteSort.TITLE_DESC).map { it.title })
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

        assertEquals(listOf("a"), NoteIndex.notes(tmp.root, NoteSort.TITLE_ASC).map { it.title })
        assertEquals(listOf("a.md"), NoteIndex.tree(tmp.root).map { it.name })

        assertEquals(listOf("a", "模板"), NoteIndex.notes(tmp.root, NoteSort.TITLE_ASC, showHidden = true).map { it.title })
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
    fun previewSkipsFrontMatterTitleAndMarkup() {
        assertEquals(
            "下周上线检查更新功能 需要先发 一个版本",
            NoteIndex.preview("---\ntags: [会议]\n---\n# 周会记录\n\n> 下周上线**检查更新**功能\n\n- 需要先发\n- [ ] 一个版本\n"),
        )
        assertEquals("看这张图 猫", NoteIndex.preview("看这张图\n![猫](assets/cat.png)\n![[cat.png]]"))
        assertEquals("", NoteIndex.preview("# 只有标题\n"))
    }
}

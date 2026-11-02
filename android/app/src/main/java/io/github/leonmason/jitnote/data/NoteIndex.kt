package io.github.leonmason.jitnote.data

import kotlinx.serialization.Serializable
import java.io.File
import java.text.Collator
import java.util.Locale

@Serializable
enum class NoteSort(val label: String) {
    MODIFIED_DESC("修改时间（新的在前）"),
    MODIFIED_ASC("修改时间（旧的在前）"),
    TITLE_ASC("名称（A → Z）"),
    TITLE_DESC("名称（Z → A）"),
}

/**
 * The notebook as the home screen shows it: every file and folder as a tree. Hidden files and
 * folders (.git, .obsidian, ...) are skipped.
 */
object NoteIndex {
    /** A file or folder in the file list, named in full like Obsidian's file explorer. */
    data class Entry(
        val path: String,
        val name: String,
        val isFolder: Boolean,
        /** Contents of a folder; empty for files. */
        val children: List<Entry>,
        /** Notes in a folder, including its subfolders; 0 for files. */
        val noteCount: Int,
        val modified: Long,
    )

    private val noteExtensions = setOf("md", "markdown", "txt")

    // Chinese by pinyin, Latin letters ignoring case.
    private val collator: Collator = Collator.getInstance(Locale.CHINA)

    fun isNote(file: File) = file.isFile && file.extension.lowercase() in noteExtensions

    /**
     * Hidden files start with "." (.obsidian, .gitignore) and are only listed when [showHidden] is on.
     * Git's own .git folder is never listed: changing it by hand can break the notebook.
     */
    fun isHidden(name: String, showHidden: Boolean) = name == ".git" || (!showHidden && name.startsWith("."))

    /**
     * Every visible file and folder under [root]. Folders come first; within each group the order
     * follows [sort], except that folders stay sorted by name when sorting by modification time.
     */
    fun tree(root: File, sort: NoteSort = NoteSort.TITLE_ASC, showHidden: Boolean = false): List<Entry> =
        entries(root, root, sort, showHidden)

    /** A child as it was when the directory was read, so sorting and listing never stat the disk again. */
    private class Child(val file: File) {
        val isDirectory = file.isDirectory
        val modified = file.lastModified()
    }

    private fun entries(root: File, dir: File, sort: NoteSort, showHidden: Boolean): List<Entry> {
        val byName = compareBy(collator) { child: Child -> child.file.name }
        // Minutes, not milliseconds: a fresh download writes every file at about the same moment,
        // and those should simply be listed by name.
        val minute = { child: Child -> child.modified / 60_000 }
        val folders = if (sort == NoteSort.TITLE_DESC) byName.reversed() else byName
        val files = when (sort) {
            NoteSort.MODIFIED_DESC -> compareByDescending(minute).then(byName)
            NoteSort.MODIFIED_ASC -> compareBy(minute).then(byName)
            NoteSort.TITLE_ASC -> byName
            NoteSort.TITLE_DESC -> byName.reversed()
        }
        // Stat each child once before sorting: a file written while the sort runs would otherwise
        // change the comparator's answers midway, which TimSort rejects with an exception.
        return (dir.listFiles() ?: emptyArray())
            .filter { !isHidden(it.name, showHidden) }
            .map { Child(it) }
            .sortedWith(compareBy<Child> { !it.isDirectory }.thenComparing { a, b -> (if (a.isDirectory) folders else files).compare(a, b) })
            .map { child ->
                val children = if (child.isDirectory) entries(root, child.file, sort, showHidden) else emptyList()
                Entry(
                    path = child.file.relativeTo(root).invariantSeparatorsPath,
                    name = child.file.name,
                    isFolder = child.isDirectory,
                    children = children,
                    noteCount = if (child.isDirectory) children.sumOf { if (it.isFolder) it.noteCount else if (isNote(File(child.file, it.name))) 1 else 0 } else 0,
                    modified = child.modified,
                )
            }
    }
}

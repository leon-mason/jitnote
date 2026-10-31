package io.github.leonmason.gitnotebook.data

import kotlinx.serialization.Serializable
import java.io.File
import java.text.Collator
import java.util.Locale

@Serializable
enum class NoteSort(val label: String) {
    MODIFIED_DESC("修改时间（新的在前）"),
    MODIFIED_ASC("修改时间（旧的在前）"),
    TITLE_ASC("标题（A → Z）"),
    TITLE_DESC("标题（Z → A）"),
}

/**
 * The notebook as the home screen shows it: every note in one flat list, and the folders on their
 * own as a tree. Hidden files and folders (.git, .obsidian, ...) are skipped.
 */
object NoteIndex {
    data class Note(
        val file: File,
        /** Relative to the notebook root, e.g. "会议/2026/周会.md". */
        val path: String,
        /** Folder relative to the notebook root; "" for the root itself. */
        val folder: String,
        val title: String,
        val modified: Long,
        val preview: String,
    )

    /** A file or folder in the file list, named in full like Obsidian's file explorer. */
    data class Entry(
        val path: String,
        val name: String,
        val isFolder: Boolean,
        /** Contents of a folder; empty for files. */
        val children: List<Entry>,
        /** Notes in a folder, including its subfolders; 0 for files. */
        val noteCount: Int,
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

    /** All notes under [folder] (and its subfolders), sorted by [sort]. */
    fun notes(root: File, sort: NoteSort, folder: String = "", showHidden: Boolean = false): List<Note> {
        val start = if (folder.isEmpty()) root else File(root, folder)
        val notes = visible(start, showHidden).filter(::isNote).map { file ->
            val path = file.relativeTo(root).invariantSeparatorsPath
            Note(
                file = file,
                path = path,
                folder = path.substringBeforeLast('/', ""),
                title = file.nameWithoutExtension,
                modified = file.lastModified(),
                preview = preview(readHead(file)),
            )
        }.toList()
        val byTitle = compareBy(collator) { note: Note -> note.title }
        // Minutes, not milliseconds: a fresh download writes every file at about the same moment,
        // and those should simply be listed by title.
        val minute = { note: Note -> note.modified / 60_000 }
        return notes.sortedWith(
            when (sort) {
                NoteSort.MODIFIED_DESC -> compareByDescending(minute).then(byTitle)
                NoteSort.MODIFIED_ASC -> compareBy(minute).then(byTitle)
                NoteSort.TITLE_ASC -> byTitle
                NoteSort.TITLE_DESC -> byTitle.reversed()
            },
        )
    }

    /** Every visible file and folder under [root]: folders first, then files, each by name. */
    fun tree(root: File, showHidden: Boolean = false): List<Entry> = entries(root, root, showHidden)

    private fun entries(root: File, dir: File, showHidden: Boolean): List<Entry> =
        (dir.listFiles() ?: emptyArray())
            .filter { !isHidden(it.name, showHidden) }
            .sortedWith(compareBy<File> { !it.isDirectory }.thenComparing(compareBy(collator) { it.name }))
            .map { child ->
                val children = if (child.isDirectory) entries(root, child, showHidden) else emptyList()
                Entry(
                    path = child.relativeTo(root).invariantSeparatorsPath,
                    name = child.name,
                    isFolder = child.isDirectory,
                    children = children,
                    noteCount = if (child.isDirectory) children.sumOf { if (it.isFolder) it.noteCount else if (isNote(File(child, it.name))) 1 else 0 } else 0,
                )
            }

    private fun visible(dir: File, showHidden: Boolean): Sequence<File> =
        dir.walkTopDown().onEnter { it == dir || !isHidden(it.name, showHidden) }.filter { !isHidden(it.name, showHidden) }

    private fun readHead(file: File): String = runCatching {
        file.bufferedReader().use { reader ->
            val buffer = CharArray(2048)
            val n = reader.read(buffer)
            if (n <= 0) "" else String(buffer, 0, n)
        }
    }.getOrDefault("")

    private val image = Regex("""!\[([^\]]*)]\([^)]*\)""")
    private val embed = Regex("""!\[\[[^\]]*]]""")
    private val link = Regex("""\[([^\]]*)]\([^)]*\)""")
    private val wikiLink = Regex("""\[\[(?:[^\]|]*\|)?([^\]]*)]]""")
    private val linePrefix = Regex("""^\s*(?:>\s*)*(?:#{1,6}\s+|[-*+]\s+|\d+[.)]\s+)?(?:\[[ xX]]\s+)?""")
    private val emphasis = Regex("""\*\*|__|~~|==|`""")

    /** The first bit of body text for the note list: no front matter, title line, or Markdown markup. */
    internal fun preview(markdown: String, maxLength: Int = 100): String {
        var lines = markdown.replace("\r\n", "\n").lines()
        if (lines.firstOrNull()?.trim() == "---") {
            val end = lines.drop(1).indexOfFirst { it.trim() == "---" }
            lines = if (end >= 0) lines.drop(end + 2) else emptyList()
        }
        lines = lines.dropWhile { it.isBlank() }
        if (lines.firstOrNull()?.trimStart()?.startsWith("# ") == true) lines = lines.drop(1)
        return lines.asSequence()
            .map { line ->
                linePrefix.replace(line, "")
                    .replace(embed, "")
                    .replace(image) { it.groupValues[1] }
                    .replace(link) { it.groupValues[1] }
                    .replace(wikiLink) { it.groupValues[1] }
                    .replace(emphasis, "")
                    .trim()
            }
            .filter { it.isNotEmpty() }
            .joinToString(" ")
            .take(maxLength)
    }
}

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

    data class Folder(val path: String, val name: String, val children: List<Folder>, val noteCount: Int)

    private val noteExtensions = setOf("md", "markdown", "txt")

    // Chinese by pinyin, Latin letters ignoring case.
    private val collator: Collator = Collator.getInstance(Locale.CHINA)

    fun isNote(file: File) = file.isFile && file.extension.lowercase() in noteExtensions

    /** All notes under [folder] (and its subfolders), sorted by [sort]. */
    fun notes(root: File, sort: NoteSort, folder: String = ""): List<Note> {
        val start = if (folder.isEmpty()) root else File(root, folder)
        val notes = visible(start).filter(::isNote).map { file ->
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

    /** The folders under [root] as a tree, each with how many notes it holds including subfolders. */
    fun folders(root: File): List<Folder> = children(root, root)

    private fun children(root: File, dir: File): List<Folder> =
        (dir.listFiles() ?: emptyArray())
            .filter { it.isDirectory && !it.name.startsWith(".") }
            .sortedWith(compareBy(collator) { it.name })
            .map { child ->
                Folder(
                    path = child.relativeTo(root).invariantSeparatorsPath,
                    name = child.name,
                    children = children(root, child),
                    noteCount = visible(child).count(::isNote),
                )
            }

    private fun visible(dir: File): Sequence<File> =
        dir.walkTopDown().onEnter { it == dir || !it.name.startsWith(".") }.filter { !it.name.startsWith(".") }

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

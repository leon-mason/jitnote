package io.github.leonmason.jitnote.data

import java.io.ByteArrayOutputStream
import java.io.File

/**
 * Before a file or folder is moved, finds the notes whose images would no longer be found
 * (design.md「首页」, decision J-13). Reads only; the notes themselves are never rewritten.
 *
 * It judges by standard Markdown paths (relative to the note, or "/" from the notebook root) and
 * ignores [NoteAssets]' look-up by file name: the notebook is also opened in Typora, GitHub and
 * other tools, which do not have that fallback. A reference counts only if it pointed at an
 * existing file before the move and points at nothing after it, so moving a folder together with
 * the images its notes use reports nothing.
 */
object BrokenImageCheck {
    // ![alt](path "title") and ![alt](<path with spaces>); one level of parentheses is allowed inside a bare path.
    private val imageReference = Regex("""!\[[^\]\n]*]\(\s*(?:<([^>\n]*)>|((?:[^\s()]|\([^\s()]*\))*))""")
    private val scheme = Regex("^[a-zA-Z][a-zA-Z0-9+.-]*:")

    /**
     * Notebook-relative paths of the notes that would lose an image if [source] (a file or folder,
     * notebook-relative) were moved into [targetFolder] ("" for the root), sorted.
     */
    fun notes(root: File, source: String, targetFolder: String): List<String> {
        val target = if (targetFolder.isEmpty()) source.substringAfterLast('/') else "$targetFolder/${source.substringAfterLast('/')}"
        if (target == source || target.startsWith("$source/")) return emptyList()
        val files = root.walkTopDown()
            .onEnter { it == root || !it.name.startsWith(".git") }
            .filter { it.isFile }
            .map { it.relativeTo(root).invariantSeparatorsPath }
            .toList()
        val before = files.toSet()
        val after = files.map { moved(it, source, target) }.toSet()
        return files.filter(::isNote).filter { note ->
            val newNote = moved(note, source, target)
            references(File(root, note).readText()).any { reference ->
                resolve(note, reference, before) != null && resolve(newNote, reference, after) == null
            }
        }.sorted()
    }

    private fun isNote(path: String) = path.lowercase().let { it.endsWith(".md") || it.endsWith(".markdown") }

    private fun moved(path: String, source: String, target: String) =
        if (path == source || path.startsWith("$source/")) target + path.removePrefix(source) else path

    /** Image paths written in [text], already without ?query / #anchor and URL-decoded; web addresses are left out. */
    private fun references(text: String): List<String> =
        imageReference.findAll(outsideCodeBlocks(text)).mapNotNull { match ->
            val raw = (match.groups[1]?.value ?: match.groups[2]?.value).orEmpty().substringBefore('?').substringBefore('#')
            val path = decode(raw)
            path.takeUnless { it.isEmpty() || it.startsWith("//") || scheme.containsMatchIn(it) }
        }.toList()

    /** An image inside a fenced code block is sample text, not an image. */
    private fun outsideCodeBlocks(text: String): String {
        var fence: String? = null
        val kept = StringBuilder()
        for (line in text.lineSequence()) {
            val trimmed = line.trimStart(' ')
            val marker = if (trimmed.startsWith("```")) "```" else if (trimmed.startsWith("~~~")) "~~~" else null
            when {
                fence == null && marker != null -> fence = marker
                fence == null -> kept.append(line).append('\n')
                marker == fence -> fence = null
            }
        }
        return kept.toString()
    }

    /** The notebook-relative file [reference] points at from [note], or null when there is none. */
    private fun resolve(note: String, reference: String, files: Set<String>): String? {
        val folder = note.substringBeforeLast('/', "")
        val joined = when {
            reference.startsWith("/") -> reference
            folder.isEmpty() -> reference
            else -> "$folder/$reference"
        }
        val parts = ArrayDeque<String>()
        for (part in joined.split('/')) {
            when (part) {
                "", "." -> Unit
                ".." -> if (parts.isEmpty()) return null else parts.removeLast()
                else -> parts.addLast(part)
            }
        }
        return parts.joinToString("/").takeIf { it in files }
    }

    /** %XX decoding that leaves a plus sign alone and keeps the raw text when it is not valid UTF-8. */
    private fun decode(path: String): String {
        if ('%' !in path) return path
        val bytes = ByteArrayOutputStream()
        var i = 0
        while (i < path.length) {
            val hex = if (path[i] == '%' && i + 2 < path.length) path.substring(i + 1, i + 3).toIntOrNull(16) else null
            if (hex != null) {
                bytes.write(hex)
                i += 3
            } else {
                bytes.write(path[i].toString().toByteArray())
                i++
            }
        }
        val decoded = bytes.toString(Charsets.UTF_8.name())
        return if ('�' in decoded && '�' !in path) path else decoded
    }
}

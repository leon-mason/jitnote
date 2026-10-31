package io.github.leonmason.gitnotebook.data

import java.io.File

/**
 * Finds the file a note refers to (images for now), the way the editors people come from do:
 * next to the note (Typora), from the notebook root (Obsidian), or by file name anywhere in the
 * notebook (Obsidian's ![[cat.png]]). Never resolves outside the notebook.
 */
class NoteAssets(private val root: File) {
    private val rootPath = root.canonicalPath

    /** Lower-case file name → notebook-relative paths, built on first use. */
    private val byName: Map<String, List<String>> by lazy {
        root.walkTopDown()
            .onEnter { it == root || !it.name.startsWith(".git") }
            .filter { it.isFile }
            .map { relative(it) }
            .groupBy { it.substringAfterLast('/').lowercase() }
    }

    /**
     * Notebook-relative path of the file [reference] points at, seen from a note in [noteFolder]
     * ("" for the root), or null if there is no such file. [reference] is already URL-decoded.
     */
    fun resolve(noteFolder: String, reference: String): String? {
        val path = reference.trim().removePrefix("./")
        if (path.isEmpty() || path.contains("://")) return null
        val candidates = if (path.startsWith("/")) {
            listOf(path.trimStart('/'))
        } else {
            listOf(if (noteFolder.isEmpty()) path else "$noteFolder/$path", path)
        }
        candidates.firstNotNullOfOrNull { existing(it) }?.let { return it }

        // Obsidian style: a bare name or a partial path, matched anywhere; the shortest path wins.
        val wanted = "/" + path.trimStart('/').lowercase()
        return byName[path.substringAfterLast('/').lowercase()]
            ?.filter { ("/" + it.lowercase()).endsWith(wanted) }
            ?.minWithOrNull(compareBy<String> { it.count { c -> c == '/' } }.thenBy { it.length })
    }

    private fun existing(relativePath: String): String? {
        val file = File(root, relativePath).canonicalFile
        if (!file.path.startsWith(rootPath + File.separator) || !file.isFile) return null
        val path = relative(file)
        return path.takeUnless { it == ".git" || it.startsWith(".git/") }
    }

    private fun relative(file: File) = file.canonicalFile.relativeTo(File(rootPath)).invariantSeparatorsPath

    companion object {
        private val imageExtensions = setOf("png", "jpg", "jpeg", "gif", "webp", "bmp", "heic", "heif", "avif", "svg")

        fun isImage(file: File) = file.extension.lowercase() in imageExtensions
    }
}

package io.github.leonmason.jitnote.data

/** Pure rules of the file tree screen: what rows show, and how paths follow renames and deletes. */
object FileTree {
    data class Row(val entry: NoteIndex.Entry, val depth: Int)

    /** The rows to draw: a folder's children only follow it when its path is in [expanded]. */
    fun visibleRows(tree: List<NoteIndex.Entry>, expanded: Set<String>): List<Row> {
        val rows = mutableListOf<Row>()
        fun walk(entries: List<NoteIndex.Entry>, depth: Int) {
            for (entry in entries) {
                rows += Row(entry, depth)
                if (entry.isFolder && entry.path in expanded) walk(entry.children, depth + 1)
            }
        }
        walk(tree, 0)
        return rows
    }

    fun find(tree: List<NoteIndex.Entry>, path: String): NoteIndex.Entry? {
        for (entry in tree) {
            if (entry.path == path) return entry
            if (entry.isFolder && path.startsWith(entry.path + "/")) find(entry.children, path)?.let { return it }
        }
        return null
    }

    /** The folder containing [path]; "" at the top level. */
    fun parent(path: String): String = path.substringBeforeLast('/', "")

    /** Every folder above [path]: "a/b/c.md" gives {"a", "a/b"}. */
    fun ancestors(path: String): Set<String> {
        val result = mutableSetOf<String>()
        var folder = parent(path)
        while (folder.isNotEmpty()) {
            result += folder
            folder = parent(folder)
        }
        return result
    }

    /** Where a new note or folder goes: the highlighted folder, or the folder of the highlighted file. */
    fun currentFolder(tree: List<NoteIndex.Entry>, highlighted: String): String {
        val entry = find(tree, highlighted) ?: return ""
        return if (entry.isFolder) entry.path else parent(entry.path)
    }

    /** [path] after [old] became [new]: only [old] itself and what is inside it change. */
    fun moved(path: String, old: String, new: String): String =
        if (path == old || path.startsWith("$old/")) new + path.removePrefix(old) else path

    /**
     * Whether [source] (a file or folder) can be moved into [folder] ("" for the root): not where it already is,
     * and a folder not into itself or anything inside it.
     */
    fun canMove(source: String, folder: String): Boolean =
        folder != parent(source) && folder != source && !folder.startsWith("$source/")

    fun renamed(expanded: Set<String>, old: String, new: String): Set<String> =
        expanded.mapTo(mutableSetOf()) { moved(it, old, new) }

    fun removed(expanded: Set<String>, path: String): Set<String> =
        expanded.filterTo(mutableSetOf()) { it != path && !it.startsWith("$path/") }
}

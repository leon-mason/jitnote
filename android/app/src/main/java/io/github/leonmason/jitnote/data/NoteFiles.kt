package io.github.leonmason.jitnote.data

import java.io.File

/** Plain file operations inside a notebook's working copy. */
object NoteFiles {
    data class Entry(val file: File, val isDirectory: Boolean, val modified: Long) {
        val name: String get() = file.name
        val title: String get() = if (isDirectory) name else name.removeSuffix(".md").removeSuffix(".markdown")
    }

    private val textExtensions = setOf(
        "md", "markdown", "txt", "text", "json", "yml", "yaml", "toml", "csv", "tsv",
        "html", "htm", "css", "js", "ts", "kt", "java", "py", "sh", "xml", "ini", "conf", "log", "org", "rst", "tex",
    )

    /** Folders first (by name), then files, most recently changed first. Hidden files are skipped. */
    fun list(dir: File): List<Entry> =
        (dir.listFiles() ?: emptyArray())
            .filterNot { it.name.startsWith(".") }
            .map { Entry(it, it.isDirectory, it.lastModified()) }
            .sortedWith(
                compareBy<Entry> { !it.isDirectory }
                    .thenBy { if (it.isDirectory) it.name.lowercase() else "" }
                    // Minutes, not milliseconds: a fresh download writes every file at about the
                    // same moment, and those should simply be listed by name.
                    .thenByDescending { it.modified / 60_000 }
                    .thenBy { it.name.lowercase() },
            )

    fun isEditable(file: File): Boolean = isTextName(file.name) && file.length() < 2_000_000

    /** Whether a file with this name is text the editor can open, judging by its extension only. */
    fun isTextName(name: String): Boolean {
        val ext = name.substringAfterLast('.', "").lowercase()
        return ext.isEmpty() || ext in textExtensions
    }

    /** Returns null if [raw] is not usable as a file name. */
    fun cleanName(raw: String): String? {
        val name = raw.trim().replace('/', '-').replace('\\', '-')
        return name.takeUnless { it.isEmpty() || it == "." || it == ".." || it.startsWith(".") }
    }

    fun createNote(dir: File, rawName: String): File {
        val name = cleanName(rawName) ?: throw IllegalArgumentException("名称不能为空，也不能以 . 开头")
        val fileName = if (name.contains('.')) name else "$name.md"
        val file = File(dir, fileName)
        require(!file.exists()) { "已存在同名文件" }
        dir.mkdirs()
        file.writeText(if (fileName.endsWith(".md")) "# ${fileName.removeSuffix(".md")}\n\n" else "")
        return file
    }

    fun createFolder(dir: File, rawName: String): File {
        val name = cleanName(rawName) ?: throw IllegalArgumentException("名称不能为空，也不能以 . 开头")
        val folder = File(dir, name)
        require(!folder.exists()) { "已存在同名文件夹" }
        folder.mkdirs()
        return folder
    }

    fun rename(file: File, rawName: String): File {
        var name = cleanName(rawName) ?: throw IllegalArgumentException("名称不能为空，也不能以 . 开头")
        if (file.isFile && !name.contains('.') && file.extension.isNotEmpty()) name += ".${file.extension}"
        val target = File(file.parentFile, name)
        if (target == file) return file
        require(!target.exists()) { "已存在同名文件" }
        require(file.renameTo(target)) { "重命名失败" }
        return target
    }

    /**
     * Moves [item] into [folder] and returns where it is now. Never replaces anything: a file or folder of the
     * same name in [folder] stops the move (design.md「首页」), and a folder cannot go into itself.
     */
    fun move(item: File, folder: File): File {
        val target = File(folder, item.name)
        if (target.canonicalFile == item.canonicalFile) return item
        require(!item.isDirectory || !(folder.canonicalPath + File.separator).startsWith(item.canonicalPath + File.separator)) {
            "不能把文件夹移动到它自己里面"
        }
        require(!target.exists()) { "目标文件夹里已有同名文件" }
        require(item.renameTo(target)) { "移动失败" }
        return target
    }

    fun relativePath(root: File, file: File): String = file.relativeTo(root).invariantSeparatorsPath
}

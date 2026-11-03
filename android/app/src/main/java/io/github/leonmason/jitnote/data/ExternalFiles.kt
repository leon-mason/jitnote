package io.github.leonmason.jitnote.data

import java.io.File
import java.io.IOException

/**
 * A notebook file the built-in editor cannot show. Another app opens the file itself and may
 * overwrite it; a later commit then records that save.
 */
object ExternalFiles {
    const val ACTION_EDIT = "android.intent.action.EDIT"
    const val ACTION_VIEW = "android.intent.action.VIEW"

    /**
     * The phone's default opener first. It receives write permission, so Save overwrites this file.
     * An editor is only the fallback when nothing handles viewing the type.
     */
    fun actions(): List<String> = listOf(ACTION_VIEW, ACTION_EDIT)

    /**
     * MIME type for [name]. [fromPlatform] is Android's MimeTypeMap when one is available; the
     * table below covers the office types either way.
     */
    fun mimeType(name: String, fromPlatform: (String) -> String? = { null }): String {
        val dot = name.lastIndexOf('.')
        if (dot < 0 || dot == name.lastIndex) return GENERIC
        val ext = name.substring(dot + 1).lowercase()
        return fromPlatform(ext)?.takeIf { it.isNotBlank() } ?: known[ext] ?: GENERIC
    }

    /** True when [file] is [root] or something inside it, after resolving ".." and links. */
    fun isInside(root: File, file: File): Boolean = try {
        val base = root.canonicalFile
        val target = file.canonicalFile
        target.path == base.path || target.path.startsWith(base.path + File.separator)
    } catch (_: IOException) {
        false
    }

    private const val GENERIC = "application/octet-stream"

    private val known = mapOf(
        "doc" to "application/msword",
        "docx" to "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "xls" to "application/vnd.ms-excel",
        "xlsx" to "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "ppt" to "application/vnd.ms-powerpoint",
        "pptx" to "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        "pdf" to "application/pdf",
        "rtf" to "application/rtf",
        "odt" to "application/vnd.oasis.opendocument.text",
        "ods" to "application/vnd.oasis.opendocument.spreadsheet",
        "odp" to "application/vnd.oasis.opendocument.presentation",
        "epub" to "application/epub+zip",
        "zip" to "application/zip",
    )
}

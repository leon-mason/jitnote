package io.github.leonmason.jitnote.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class ExternalFilesTest {
    @get:Rule
    val tmp = TemporaryFolder()

    @Test
    fun officeTypesKeepTheirMimeWithoutThePlatform() {
        assertEquals(
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            ExternalFiles.mimeType("周报.DOCX"),
        )
        assertEquals(
            "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            ExternalFiles.mimeType("表.xlsx"),
        )
        assertEquals("application/pdf", ExternalFiles.mimeType("a.pdf"))
    }

    @Test
    fun platformMappingWinsAndUnknownTypesStayGeneric() {
        assertEquals("application/x-custom", ExternalFiles.mimeType("a.docx") { "application/x-custom" })
        assertEquals("application/octet-stream", ExternalFiles.mimeType("a.xyz"))
        assertEquals("application/octet-stream", ExternalFiles.mimeType("README"))
        assertEquals("application/octet-stream", ExternalFiles.mimeType("尾点."))
    }

    @Test
    fun theDefaultOpenerIsTriedBeforeAnEditor() {
        assertEquals(
            listOf("android.intent.action.VIEW", "android.intent.action.EDIT"),
            ExternalFiles.actions(),
        )
    }

    @Test
    fun docxIsNotOpenedByTheEditorOrTheImageViewer() {
        val file = File(tmp.root, "周报.docx")
        file.writeText("not really a document")
        assertFalse(NoteAssets.isImage(file))
        assertFalse(NoteFiles.isEditable(file))
    }

    @Test
    fun onlyFilesInsideTheNotebookCanBeHandedOut() {
        val notebook = File(tmp.root, "nb").apply { mkdirs() }
        val doc = File(notebook, "子/周报.docx").apply {
            parentFile!!.mkdirs()
            writeText("x")
        }
        val outside = File(tmp.root, "secret.txt").apply { writeText("no") }
        val lookalike = File(tmp.root, "nb-other/file.docx").apply {
            parentFile!!.mkdirs()
            writeText("x")
        }

        assertTrue(ExternalFiles.isInside(notebook, doc))
        assertFalse(ExternalFiles.isInside(notebook, outside))
        assertFalse(ExternalFiles.isInside(notebook, File(notebook, "../secret.txt")))
        assertFalse(ExternalFiles.isInside(notebook, lookalike))
    }
}

package io.github.leonmason.jitnote.data

import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class StateStoreTest {
    @get:Rule
    val tmp = TemporaryFolder()

    @Test
    fun oldStateFileKeepsAccountsAndNotebooks() {
        val file = File(tmp.root, "state.json")
        file.writeText(
            """
            {
              "accounts": [{"id":"a1","provider":"GITHUB","login":"me","email":"me@example.com","encryptedToken":"x","createdAt":1}],
              "notebooks": [{"id":"n1","name":"笔记","accountId":"a1","remoteUrl":"https://github.com/me/notes.git","dir":"notes","createdAt":2}],
              "currentNotebookId": "n1",
              "noteSort": "MODIFIED_DESC",
              "showHiddenFiles": true
            }
            """.trimIndent(),
        )
        val state = StateStore(file).state.value
        assertEquals(1, state.accounts.size)
        assertEquals(1, state.notebooks.size)
        assertEquals("n1", state.currentNotebookId)
        assertEquals(NoteSort.TITLE_ASC, state.fileSort)
        assertEquals(ViewMode.EDIT, state.defaultViewMode)
        assertEquals(false, state.syncOnLaunch)
        assertEquals(emptyMap<String, Set<String>>(), state.expandedFolders)
    }
}

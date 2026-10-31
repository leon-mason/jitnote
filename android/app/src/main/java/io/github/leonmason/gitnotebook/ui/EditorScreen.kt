package io.github.leonmason.gitnotebook.ui

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.History
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.github.leonmason.gitnotebook.data.NoteFiles
import io.github.leonmason.gitnotebook.data.Notebook
import io.github.leonmason.gitnotebook.data.Notebooks
import io.github.leonmason.gitnotebook.data.SyncState
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import java.io.File

/**
 * Writes the note to disk only when its text actually changed. Safe to call from any thread.
 * Nothing is written until the user has edited ([markEdited]): just opening a note must never
 * rewrite it, even if the editor would format some Markdown differently.
 */
private class NoteSaver(private val file: File, initial: String) {
    private var saved = initial

    @Volatile
    var edited = false
        private set

    fun markEdited() {
        edited = true
    }

    @Synchronized
    fun save(text: String?): Boolean {
        if (!edited || text == null || text == saved) return false
        file.parentFile?.mkdirs()
        file.writeText(text)
        saved = text
        return true
    }
}

@Composable
fun EditorScreen(notebooks: Notebooks, nav: Navigator, screen: Screen.Editor) {
    val notebook = notebooks.notebook(screen.notebookId)
    if (notebook == null) {
        LaunchedEffect(Unit) { nav.popUntil { it == Screen.Home } }
        return
    }
    val syncStates by notebooks.syncStates.collectAsStateWithLifecycle()
    val syncing = syncStates[notebook.id] == SyncState.Running
    val root = notebooks.dir(notebook)
    val file = File(root, screen.path)
    var content by remember { mutableStateOf<String?>(null) }

    // Never edit while a sync is rewriting files; (re)load once it is done.
    LaunchedEffect(syncing) {
        if (!syncing) content = withContext(Dispatchers.IO) { if (file.exists()) file.readText() else "" }
    }

    Scaffold(
        topBar = {
            BackTopBar(NoteFiles.Entry(file, false, 0).title, onBack = nav::pop) {
                IconButton(onClick = { nav.push(Screen.History(notebook.id, screen.path)) }) {
                    Icon(Icons.Outlined.History, contentDescription = "历史版本")
                }
            }
        },
    ) { padding ->
        Box(Modifier.fillMaxSize().padding(padding).imePadding()) {
            val text = content
            when {
                syncing -> Waiting("正在同步，请稍候…")
                text == null -> Waiting("正在打开…")
                file.extension.lowercase() in setOf("md", "markdown") ->
                    RichNoteEditor(notebooks, notebook, root, screen.path, file, text) { image ->
                        nav.push(Screen.Image(notebook.id, image))
                    }
                else -> PlainTextEditor(notebooks, notebook, file, text)
            }
        }
    }
}

@Composable
private fun RichNoteEditor(
    notebooks: Notebooks,
    notebook: Notebook,
    root: File,
    path: String,
    file: File,
    text: String,
    onOpenImage: (String) -> Unit,
) {
    val saver = remember(text) { NoteSaver(file, text) }
    val handle = remember(saver) {
        EditorHandle(onClose = { final ->
            saver.save(final)
            notebooks.commitInBackground(notebook)
        })
    }
    // Leaving the app also counts as "done editing": save and record a version.
    LifecycleEventEffect(Lifecycle.Event.ON_STOP) {
        handle.read { latest ->
            saver.save(latest)
            notebooks.commitInBackground(notebook)
        }
    }
    NoteWebView(
        notebookRoot = root,
        notePath = path,
        content = text,
        readonly = false,
        handle = handle,
        modifier = Modifier.fillMaxSize(),
        onChange = {
            saver.markEdited()
            saver.save(it)
        },
        onOpenImage = onOpenImage,
    )
}

@Composable
private fun PlainTextEditor(notebooks: Notebooks, notebook: Notebook, file: File, initial: String) {
    val saver = remember(initial) { NoteSaver(file, initial) }
    var value by remember(initial) { mutableStateOf(initial) }
    LaunchedEffect(value) {
        delay(800)
        withContext(Dispatchers.IO) { saver.save(value) }
    }
    LifecycleEventEffect(Lifecycle.Event.ON_STOP) {
        saver.save(value)
        notebooks.commitInBackground(notebook)
    }
    androidx.compose.runtime.DisposableEffect(saver) {
        onDispose {
            saver.save(value)
            notebooks.commitInBackground(notebook)
        }
    }
    BasicTextField(
        value = value,
        onValueChange = {
            saver.markEdited()
            value = it
        },
        textStyle = MaterialTheme.typography.bodyLarge.copy(
            color = MaterialTheme.colorScheme.onSurface,
            fontFamily = FontFamily.Monospace,
        ),
        cursorBrush = SolidColor(MaterialTheme.colorScheme.primary),
        modifier = Modifier.fillMaxSize().padding(16.dp),
    )
}

@Composable
fun Waiting(message: String) {
    Column(Modifier.fillMaxSize(), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = androidx.compose.foundation.layout.Arrangement.Center) {
        CircularProgressIndicator()
        Spacer(Modifier.size(16.dp))
        Text(message, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

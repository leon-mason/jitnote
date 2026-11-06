package io.github.leonmason.jitnote.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.Toc
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material.icons.outlined.History
import androidx.compose.material.icons.outlined.Visibility
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
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.github.leonmason.jitnote.data.NoteFiles
import io.github.leonmason.jitnote.data.Notebook
import io.github.leonmason.jitnote.data.Notebooks
import io.github.leonmason.jitnote.data.SyncState
import io.github.leonmason.jitnote.data.ViewMode
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlin.coroutines.resume
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
    val appState by notebooks.state.collectAsStateWithLifecycle()
    val isMarkdown = file.extension.lowercase() in setOf("md", "markdown")
    // Only what the user toggled on this note is remembered; otherwise new notes edit and the rest follow the setting.
    val mode = nav.editorMode[screen] ?: if (screen.startEditing) ViewMode.EDIT else appState.defaultViewMode

    // Never edit while a sync is rewriting files; (re)load once it is done.
    LaunchedEffect(syncing) {
        if (!syncing) content = withContext(Dispatchers.IO) { if (file.exists()) file.readText() else "" }
    }
    val text = content
    // The outline reads this same editor; a new file makes a new saver so an old note is not written again.
    val saver = remember(text, isMarkdown) { if (isMarkdown && text != null) NoteSaver(file, text) else null }
    val handle = remember(saver) {
        saver?.let {
            EditorHandle(onClose = { final ->
                it.save(final)
                notebooks.refreshUnsyncedInBackground(notebook)
            })
        }
    }
    // The heading list is only drawn beside a Markdown preview (design.md 「编辑器」).
    var outlineOpen by remember { mutableStateOf(false) }
    var headings by remember { mutableStateOf<List<OutlineHeading>?>(null) }
    val outlineShown = isMarkdown && outlineOpen && mode == ViewMode.PREVIEW && !syncing && text != null
    LaunchedEffect(outlineShown, text, handle) {
        if (!outlineShown || handle == null) return@LaunchedEffect
        headings = null
        // The editor page is large; the first load can take a few seconds (design.md 「编辑器」).
        repeat(50) {
            val found = handle.awaitHeadings()
            if (found != null) {
                headings = found
                return@LaunchedEffect
            }
            delay(100)
        }
        headings = handle.awaitHeadings() ?: emptyList()
    }

    Scaffold(
        topBar = {
            BackTopBar(NoteFiles.Entry(file, false, 0).title, onBack = nav::pop) {
                if (isMarkdown) {
                    val toPreview = mode == ViewMode.EDIT
                    IconButton(onClick = { nav.editorMode[screen] = if (toPreview) ViewMode.PREVIEW else ViewMode.EDIT }) {
                        Icon(
                            if (toPreview) Icons.Outlined.Visibility else Icons.Outlined.Edit,
                            contentDescription = if (toPreview) "预览" else "编辑",
                        )
                    }
                }
                IconButton(onClick = { nav.push(Screen.History(notebook.id, screen.path)) }) {
                    Icon(Icons.Outlined.History, contentDescription = "历史版本")
                }
                if (isMarkdown) {
                    IconButton(onClick = {
                        if (outlineShown) {
                            outlineOpen = false
                        } else {
                            outlineOpen = true
                            if (mode != ViewMode.PREVIEW) nav.editorMode[screen] = ViewMode.PREVIEW
                        }
                    }) {
                        Icon(
                            Icons.AutoMirrored.Outlined.Toc,
                            contentDescription = if (outlineShown) "收起大纲" else "大纲",
                            tint = if (outlineShown) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurface,
                        )
                    }
                }
            }
        },
    ) { padding ->
        Box(Modifier.fillMaxSize().padding(padding).imePadding()) {
            when {
                syncing -> Waiting("正在同步，请稍候…")
                text == null -> Waiting("正在打开…")
                isMarkdown && saver != null && handle != null ->
                    Row(Modifier.fillMaxSize()) {
                        if (outlineShown) {
                            NoteOutline(headings) { handle.scrollToHeading(it) }
                            Box(
                                Modifier
                                    .width(1.dp)
                                    .fillMaxHeight()
                                    .background(MaterialTheme.colorScheme.outlineVariant),
                            )
                        }
                        RichNoteEditor(
                            notebooks, notebook, root, screen.path, text, mode == ViewMode.PREVIEW,
                            saver, handle,
                            Modifier.weight(1f).fillMaxHeight(),
                        ) { image -> nav.push(Screen.Image(notebook.id, image)) }
                    }
                else -> PlainTextEditor(notebooks, notebook, file, text)
            }
        }
    }
}

/** 220dp fits a short heading without covering the note (design.md 「编辑器」). */
@Composable
private fun NoteOutline(headings: List<OutlineHeading>?, onSelect: (Int) -> Unit) {
    Column(
        Modifier
            .width(220.dp)
            .fillMaxHeight()
            .verticalScroll(rememberScrollState())
            .padding(8.dp),
    ) {
        when {
            headings == null -> Text("正在读取…", color = MaterialTheme.colorScheme.onSurfaceVariant)
            headings.isEmpty() -> Text("这篇笔记没有标题", color = MaterialTheme.colorScheme.onSurfaceVariant)
            else -> headings.forEachIndexed { index, item ->
                Text(
                    text = item.text.ifBlank { "（空标题）" },
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable { onSelect(index) }
                        .padding(start = ((item.level - 1).coerceAtLeast(0) * 12).dp, top = 6.dp, bottom = 6.dp),
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                    style = MaterialTheme.typography.bodyMedium,
                )
            }
        }
    }
}

private suspend fun EditorHandle.awaitHeadings(): List<OutlineHeading>? = suspendCancellableCoroutine { cont ->
    headings { if (cont.isActive) cont.resume(it) }
}

@Composable
private fun RichNoteEditor(
    notebooks: Notebooks,
    notebook: Notebook,
    root: File,
    path: String,
    text: String,
    readonly: Boolean,
    saver: NoteSaver,
    handle: EditorHandle,
    modifier: Modifier = Modifier,
    onOpenImage: (String) -> Unit,
) {
    // Leaving the app also counts as "done editing": save it. The version is recorded by the next sync.
    LifecycleEventEffect(Lifecycle.Event.ON_STOP) {
        handle.read { latest ->
            saver.save(latest)
            notebooks.refreshUnsyncedInBackground(notebook)
        }
    }
    NoteWebView(
        notebookRoot = root,
        notePath = path,
        content = text,
        readonly = readonly,
        handle = handle,
        modifier = modifier,
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
        notebooks.refreshUnsyncedInBackground(notebook)
    }
    androidx.compose.runtime.DisposableEffect(saver) {
        onDispose {
            saver.save(value)
            notebooks.refreshUnsyncedInBackground(notebook)
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

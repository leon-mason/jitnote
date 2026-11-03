package io.github.leonmason.jitnote.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import io.github.leonmason.jitnote.core.Version
import io.github.leonmason.jitnote.data.NoteFiles
import io.github.leonmason.jitnote.data.Notebooks
import kotlinx.coroutines.launch
import java.io.File

@Composable
fun HistoryScreen(notebooks: Notebooks, nav: Navigator, screen: Screen.History) {
    val notebook = notebooks.notebook(screen.notebookId) ?: return
    var versions by remember { mutableStateOf<List<Version>?>(null) }
    LaunchedEffect(screen) {
        versions = notebooks.withLock(notebook) { notebooks.git(notebook).history(screen.path) }
    }
    val title = NoteFiles.Entry(File(screen.path), false, 0).title

    Scaffold(topBar = { BackTopBar("「$title」的历史版本", onBack = nav::pop) }) { padding ->
        val list = versions
        when {
            list == null -> Box(Modifier.padding(padding)) { Waiting("正在读取…") }
            list.isEmpty() -> EmptyState("还没有历史版本", "每次写完离开笔记，都会自动留下一个版本。", Modifier.padding(padding))
            else -> LazyColumn(contentPadding = padding) {
                item {
                    Text(
                        "点开任意一个版本可以查看内容，也可以恢复成那个版本。",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(16.dp),
                    )
                }
                items(list, key = { it.commit }) { version ->
                    ListItem(
                        headlineContent = { Text(friendlyTime(version.time)) },
                        supportingContent = {
                            Text("${plainMessage(version.message)} · ${version.author}", maxLines = 2, overflow = TextOverflow.Ellipsis)
                        },
                        modifier = Modifier.clickable { nav.push(Screen.VersionPreview(notebook.id, screen.path, version)) },
                    )
                    HorizontalDivider()
                }
            }
        }
    }
}

@Composable
fun VersionPreviewScreen(notebooks: Notebooks, nav: Navigator, screen: Screen.VersionPreview) {
    val notebook = notebooks.notebook(screen.notebookId) ?: return
    var content by remember { mutableStateOf<String?>(null) }
    var missing by remember { mutableStateOf(false) }
    var binary by remember { mutableStateOf(false) }
    var confirming by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    LaunchedEffect(screen) {
        val bytes = notebooks.withLock(notebook) { notebooks.git(notebook).readAt(screen.version.commit, screen.path) }
        missing = bytes == null
        // Office files and the like are bytes, not notes. Showing them as text would be garbage.
        binary = bytes != null && !NoteFiles.isTextName(screen.path)
        content = if (missing || binary) "" else bytes!!.toString(Charsets.UTF_8)
    }

    Scaffold(
        topBar = {
            BackTopBar(friendlyTime(screen.version.time), onBack = nav::pop) {
                TextButton(onClick = { confirming = true }, enabled = content != null) { Text("恢复这个版本") }
            }
        },
    ) { padding ->
        val text = content
        Box(Modifier.fillMaxSize().padding(padding)) {
            when {
                text == null -> Waiting("正在读取…")
                missing -> EmptyState("这个版本里笔记已被删除", "恢复这个版本会删除当前的笔记。")
                binary -> EmptyState("这个版本不能在这里预览", "文件原样留在历史里。可以恢复成这个版本。")
                else -> NoteWebView(
                    notebookRoot = notebooks.dir(notebook),
                    notePath = screen.path,
                    content = text,
                    readonly = true,
                    handle = remember { EditorHandle() },
                    modifier = Modifier.fillMaxSize(),
                    onOpenImage = { nav.push(Screen.Image(notebook.id, it)) },
                )
            }
        }
    }

    if (confirming) {
        ConfirmDialog(
            title = "恢复成这个版本？",
            text = "当前内容会被这个版本替换。不用担心，当前内容也会留在历史版本里。",
            confirmLabel = "恢复",
            onDismiss = { confirming = false },
        ) {
            confirming = false
            scope.launch {
                notebooks.restore(notebook, screen.path, screen.version.commit)
                nav.popUntil { it is Screen.Editor || it == Screen.Home }
            }
        }
    }
}

/** Commit summaries are already in plain words; drop the "来自 …" body if present. */
private fun plainMessage(message: String) = message.lineSequence().first()

package io.github.leonmason.gitnotebook.ui

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.Image
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.InsertDriveFile
import androidx.compose.material.icons.automirrored.outlined.Notes
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.outlined.CreateNewFolder
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material.icons.outlined.Image
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExtendedFloatingActionButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.github.leonmason.gitnotebook.data.NoteAssets
import io.github.leonmason.gitnotebook.data.NoteFiles
import io.github.leonmason.gitnotebook.data.Notebooks
import io.github.leonmason.gitnotebook.data.SyncState
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

@Composable
fun FolderScreen(notebooks: Notebooks, nav: Navigator, screen: Screen.Folder) {
    val state by notebooks.state.collectAsStateWithLifecycle()
    val notebook = state.notebooks.firstOrNull { it.id == screen.notebookId }
    if (notebook == null) {
        LaunchedEffect(Unit) { nav.popUntil { it == Screen.Home } }
        return
    }
    val syncStates by notebooks.syncStates.collectAsStateWithLifecycle()
    val syncState = syncStates[notebook.id]
    val root = notebooks.dir(notebook)
    val folder = File(root, screen.path)

    var refresh by remember { mutableIntStateOf(0) }
    var entries by remember { mutableStateOf<List<NoteFiles.Entry>?>(null) }
    var conflictCount by remember { mutableIntStateOf(0) }
    val snackbar = remember { SnackbarHostState() }
    val scope = rememberCoroutineScope()

    var creating by remember { mutableStateOf<Boolean?>(null) } // true = note, false = folder
    var renaming by remember { mutableStateOf<NoteFiles.Entry?>(null) }
    var deleting by remember { mutableStateOf<NoteFiles.Entry?>(null) }

    LaunchedEffect(refresh, syncState) {
        if (syncState == SyncState.Running) return@LaunchedEffect
        entries = withContext(Dispatchers.IO) { NoteFiles.list(folder) }
        conflictCount = notebooks.conflicts(notebook).size
    }
    SyncMessages(notebooks, syncStates, snackbar)

    Scaffold(
        topBar = {
            BackTopBar(
                title = if (screen.path.isEmpty()) notebook.name else screen.path.substringAfterLast('/'),
                onBack = nav::pop,
            ) {
                IconButton(onClick = { creating = false }) {
                    Icon(Icons.Outlined.CreateNewFolder, contentDescription = "新建文件夹")
                }
                SyncButton(syncState == SyncState.Running) { notebooks.startSync(notebook) }
            }
        },
        floatingActionButton = {
            ExtendedFloatingActionButton(
                onClick = { creating = true },
                icon = { Icon(Icons.Default.Add, contentDescription = null) },
                text = { Text("新建笔记") },
            )
        },
        snackbarHost = { SnackbarHost(snackbar) },
    ) { padding ->
        val list = entries
        LazyColumn(
            contentPadding = PaddingValues(
                top = padding.calculateTopPadding(),
                bottom = padding.calculateBottomPadding() + 96.dp,
            ),
        ) {
            if (screen.path.isEmpty()) {
                item { Box(Modifier.padding(horizontal = 16.dp, vertical = 4.dp)) { SyncStatusLine(notebook, syncState) } }
            }
            if (conflictCount > 0) {
                item {
                    Card(
                        onClick = { nav.push(Screen.Conflicts(notebook.id)) },
                        colors = CardDefaults.cardColors(
                            containerColor = MaterialTheme.colorScheme.tertiaryContainer,
                            contentColor = MaterialTheme.colorScheme.onTertiaryContainer,
                        ),
                        modifier = Modifier.fillMaxWidth().padding(16.dp),
                    ) {
                        Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
                            Icon(Icons.Outlined.Info, contentDescription = null)
                            Spacer(Modifier.size(12.dp))
                            Column {
                                Text("有 $conflictCount 篇笔记在两个地方都改过", style = MaterialTheme.typography.titleSmall)
                                Text("已自动保留较新的版本。点这里查看，也可以换回另一个版本。", style = MaterialTheme.typography.bodySmall)
                            }
                        }
                    }
                }
            }
            if (list != null && list.isEmpty()) {
                item {
                    EmptyState(
                        title = "这里还没有笔记",
                        body = "点右下角「新建笔记」写第一篇。\n写完会自动保存，点右上角的同步按钮就会保存到云端。",
                        modifier = Modifier.padding(top = 48.dp),
                    )
                }
            }
            items(list.orEmpty(), key = { it.file.path }) { entry ->
                EntryRow(
                    entry = entry,
                    onOpen = {
                        val path = NoteFiles.relativePath(root, entry.file)
                        when {
                            entry.isDirectory -> nav.push(Screen.Folder(notebook.id, path))
                            NoteAssets.isImage(entry.file) -> nav.push(Screen.Image(notebook.id, path))
                            NoteFiles.isEditable(entry.file) -> nav.push(Screen.Editor(notebook.id, path))
                            else -> scope.launch { snackbar.showSnackbar("这种文件暂时不能在手机上打开") }
                        }
                    },
                    onHistory = { nav.push(Screen.History(notebook.id, NoteFiles.relativePath(root, entry.file))) },
                    onRename = { renaming = entry },
                    onDelete = { deleting = entry },
                )
            }
        }
    }

    creating?.let { isNote ->
        TextInputDialog(
            title = if (isNote) "新建笔记" else "新建文件夹",
            label = if (isNote) "标题" else "文件夹名称",
            confirmLabel = "创建",
            onDismiss = { creating = null },
        ) { name ->
            try {
                if (isNote) {
                    val file = NoteFiles.createNote(folder, name)
                    nav.push(Screen.Editor(notebook.id, NoteFiles.relativePath(root, file)))
                } else {
                    NoteFiles.createFolder(folder, name)
                    refresh++
                }
                creating = null
                null
            } catch (e: IllegalArgumentException) {
                e.message
            }
        }
    }

    renaming?.let { entry ->
        TextInputDialog(
            title = "重命名",
            label = "新名称",
            initial = entry.title,
            onDismiss = { renaming = null },
        ) { name ->
            try {
                NoteFiles.rename(entry.file, name)
                renaming = null
                notebooks.commitInBackground(notebook)
                refresh++
                null
            } catch (e: IllegalArgumentException) {
                e.message
            }
        }
    }

    deleting?.let { entry ->
        ConfirmDialog(
            title = "删除「${entry.title}」？",
            text = if (entry.isDirectory) {
                "文件夹里的所有笔记都会被删除。同步后其他设备上也会删除。\n误删了也不用怕，历史版本里还能找回。"
            } else {
                "同步后其他设备上也会删除。\n误删了也不用怕，历史版本里还能找回。"
            },
            confirmLabel = "删除",
            destructive = true,
            onDismiss = { deleting = null },
        ) {
            deleting = null
            scope.launch {
                notebooks.withLock(notebook) { entry.file.deleteRecursively() }
                notebooks.commit(notebook)
                refresh++
            }
        }
    }
}

/** A small preview of an image file; falls back to an icon while loading or if it can't be read. */
@Composable
private fun Thumbnail(file: File) {
    val image by produceState<ImageBitmap?>(null, file) {
        value = withContext(Dispatchers.IO) { runCatching { decode(file, maxSide = 160) }.getOrNull() }
    }
    val bitmap = image
    if (bitmap == null) {
        Icon(Icons.Outlined.Image, contentDescription = null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
    } else {
        Image(
            bitmap = bitmap,
            contentDescription = null,
            contentScale = ContentScale.Crop,
            modifier = Modifier.size(40.dp).clip(MaterialTheme.shapes.small),
        )
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun EntryRow(
    entry: NoteFiles.Entry,
    onOpen: () -> Unit,
    onHistory: () -> Unit,
    onRename: () -> Unit,
    onDelete: () -> Unit,
) {
    var menu by remember { mutableStateOf(false) }
    Box {
        ListItem(
            leadingContent = {
                if (NoteAssets.isImage(entry.file)) {
                    Thumbnail(entry.file)
                } else {
                    Icon(
                        when {
                            entry.isDirectory -> Icons.Outlined.Folder
                            NoteFiles.isEditable(entry.file) -> Icons.AutoMirrored.Outlined.Notes
                            else -> Icons.AutoMirrored.Outlined.InsertDriveFile
                        },
                        contentDescription = null,
                        tint = if (entry.isDirectory) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            },
            headlineContent = { Text(entry.title, maxLines = 1) },
            supportingContent = if (entry.isDirectory) null else ({ Text(friendlyTime(entry.modified)) }),
            modifier = Modifier.combinedClickable(onClick = onOpen, onLongClick = { menu = true }),
        )
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            if (!entry.isDirectory) {
                DropdownMenuItem(text = { Text("历史版本") }, enabled = !NoteAssets.isImage(entry.file), onClick = {
                    menu = false
                    onHistory()
                })
            }
            DropdownMenuItem(text = { Text("重命名") }, onClick = {
                menu = false
                onRename()
            })
            DropdownMenuItem(text = { Text("删除") }, onClick = {
                menu = false
                onDelete()
            })
        }
    }
}

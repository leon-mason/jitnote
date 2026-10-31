package io.github.leonmason.gitnotebook.ui

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.outlined.AccountCircle
import androidx.compose.material.icons.outlined.Book
import androidx.compose.material.icons.outlined.CloudDone
import androidx.compose.material.icons.outlined.CloudOff
import androidx.compose.material.icons.outlined.Sync
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExtendedFloatingActionButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.github.leonmason.gitnotebook.data.Notebook
import io.github.leonmason.gitnotebook.data.Notebooks
import io.github.leonmason.gitnotebook.data.SyncState
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HomeScreen(notebooks: Notebooks, nav: Navigator) {
    val state by notebooks.state.collectAsStateWithLifecycle()
    val syncStates by notebooks.syncStates.collectAsStateWithLifecycle()
    val snackbar = remember { SnackbarHostState() }
    val scope = rememberCoroutineScope()
    var renaming by remember { mutableStateOf<Notebook?>(null) }
    var deleting by remember { mutableStateOf<Pair<Notebook, Boolean>?>(null) }

    SyncMessages(notebooks, syncStates, snackbar)

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("我的笔记本", fontWeight = FontWeight.SemiBold) },
                actions = {
                    IconButton(onClick = { nav.push(Screen.Accounts) }) {
                        Icon(Icons.Outlined.AccountCircle, contentDescription = "云端账号")
                    }
                },
            )
        },
        floatingActionButton = {
            if (state.accounts.isNotEmpty()) {
                ExtendedFloatingActionButton(
                    onClick = { nav.push(Screen.NewNotebook) },
                    icon = { Icon(Icons.Default.Add, contentDescription = null) },
                    text = { Text("添加笔记本") },
                )
            }
        },
        snackbarHost = { SnackbarHost(snackbar) },
    ) { padding ->
        when {
            state.accounts.isEmpty() -> Welcome(Modifier.padding(padding)) { nav.push(Screen.AddAccount) }
            state.notebooks.isEmpty() -> EmptyState(
                title = "还没有笔记本",
                body = "笔记本就像一个文件夹，里面可以放很多篇笔记。\n点右下角「添加笔记本」，新建一个，或者用账号里已有的。",
                modifier = Modifier.padding(padding),
            )
            else -> LazyColumn(
                contentPadding = PaddingValues(
                    start = 16.dp,
                    end = 16.dp,
                    top = padding.calculateTopPadding() + 8.dp,
                    bottom = padding.calculateBottomPadding() + 96.dp,
                ),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                items(state.notebooks, key = { it.id }) { notebook ->
                    NotebookCard(
                        notebook = notebook,
                        syncState = syncStates[notebook.id],
                        onOpen = { nav.push(Screen.Folder(notebook.id)) },
                        onSync = { notebooks.startSync(notebook) },
                        onRename = { renaming = notebook },
                        onDelete = {
                            scope.launch { deleting = notebook to notebooks.hasUnsyncedWork(notebook) }
                        },
                    )
                }
            }
        }
    }

    renaming?.let { notebook ->
        TextInputDialog(
            title = "重命名笔记本",
            label = "笔记本名称",
            initial = notebook.name,
            onDismiss = { renaming = null },
        ) { name ->
            if (name.isBlank()) return@TextInputDialog "名称不能为空"
            notebooks.rename(notebook, name.trim())
            renaming = null
            null
        }
    }

    deleting?.let { (notebook, unsynced) ->
        ConfirmDialog(
            title = "从这台手机移除「${notebook.name}」？",
            text = if (unsynced) {
                "这个笔记本还有没同步到云端的修改，移除后这些修改会丢失。建议先点同步。\n\n云端的笔记不会被删除，以后可以重新下载。"
            } else {
                "只是从这台手机上移除，云端的笔记不会被删除，以后可以重新下载。"
            },
            confirmLabel = "移除",
            destructive = true,
            onDismiss = { deleting = null },
        ) {
            deleting = null
            scope.launch { notebooks.deleteLocal(notebook) }
        }
    }
}

@Composable
private fun Welcome(modifier: Modifier, onStart: () -> Unit) {
    Column(
        modifier.fillMaxSize().padding(24.dp),
        verticalArrangement = Arrangement.Center,
    ) {
        Icon(
            Icons.Outlined.Book,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.primary,
            modifier = Modifier.size(56.dp),
        )
        Spacer(Modifier.size(16.dp))
        Text("欢迎使用 Git 笔记本", style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.SemiBold)
        Spacer(Modifier.size(12.dp))
        Text(
            "你的笔记会保存在你自己的 Gitee 或 GitHub 账号里，只有你自己能看到。" +
                "换手机、在电脑上打开都不会丢。\n\n这个 App 没有服务器，不会收集你的任何数据。",
            style = MaterialTheme.typography.bodyLarge,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Spacer(Modifier.size(24.dp))
        Button(onClick = onStart, modifier = Modifier.fillMaxWidth()) { Text("第一步：连接云端账号") }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun NotebookCard(
    notebook: Notebook,
    syncState: SyncState?,
    onOpen: () -> Unit,
    onSync: () -> Unit,
    onRename: () -> Unit,
    onDelete: () -> Unit,
) {
    var menu by remember { mutableStateOf(false) }
    Card(
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainer),
        modifier = Modifier.fillMaxWidth().combinedClickable(onClick = onOpen, onLongClick = { menu = true }),
    ) {
        Row(Modifier.padding(start = 16.dp, top = 12.dp, bottom = 12.dp, end = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text(
                    notebook.name,
                    style = MaterialTheme.typography.titleMedium,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Spacer(Modifier.size(4.dp))
                SyncStatusLine(notebook, syncState)
            }
            SyncButton(syncState == SyncState.Running, onSync)
            Box {
                IconButton(onClick = { menu = true }) { Icon(Icons.Default.MoreVert, contentDescription = "更多") }
                DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                    DropdownMenuItem(text = { Text("重命名") }, onClick = {
                        menu = false
                        onRename()
                    })
                    DropdownMenuItem(text = { Text("从这台手机移除") }, onClick = {
                        menu = false
                        onDelete()
                    })
                }
            }
        }
    }
}

@Composable
fun SyncStatusLine(notebook: Notebook, syncState: SyncState?) {
    val (icon, text, isError) = when {
        syncState == SyncState.Running -> Triple(Icons.Outlined.Sync, "正在同步…", false)
        notebook.lastSyncError != null -> Triple(Icons.Outlined.CloudOff, "同步没有成功：${notebook.lastSyncError}", true)
        notebook.lastSyncAt != null -> Triple(Icons.Outlined.CloudDone, "已同步 · ${friendlyTime(notebook.lastSyncAt)}", false)
        else -> Triple(Icons.Outlined.CloudOff, "还没有同步过", false)
    }
    val color = if (isError) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant
    Row(verticalAlignment = Alignment.CenterVertically) {
        Icon(icon, contentDescription = null, tint = color, modifier = Modifier.size(16.dp))
        Spacer(Modifier.width(6.dp))
        Text(text, style = MaterialTheme.typography.bodySmall, color = color, maxLines = 2, overflow = TextOverflow.Ellipsis)
    }
}

/** The one sync button. Shows a spinner while syncing. */
@Composable
fun SyncButton(running: Boolean, onSync: () -> Unit) {
    IconButton(onClick = onSync, enabled = !running) {
        if (running) {
            CircularProgressIndicator(strokeWidth = 2.dp, modifier = Modifier.size(22.dp))
        } else {
            Icon(Icons.Outlined.Sync, contentDescription = "同步")
        }
    }
}

/** Shows each finished sync result once, on whichever screen is visible. */
@Composable
fun SyncMessages(notebooks: Notebooks, syncStates: Map<String, SyncState>, snackbar: SnackbarHostState, onFinished: () -> Unit = {}) {
    val finished = syncStates.values.filterIsInstance<SyncState.Finished>().maxByOrNull { it.seq }
    LaunchedEffect(finished) {
        if (finished != null && notebooks.markShown(finished)) {
            onFinished()
            snackbar.showSnackbar(finished.message)
        }
    }
}

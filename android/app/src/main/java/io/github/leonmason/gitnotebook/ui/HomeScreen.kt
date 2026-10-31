package io.github.leonmason.gitnotebook.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Sort
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Menu
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.DrawerValue
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExtendedFloatingActionButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalNavigationDrawer
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.rememberDrawerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
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
import io.github.leonmason.gitnotebook.data.AppUpdates
import io.github.leonmason.gitnotebook.data.NoteAssets
import io.github.leonmason.gitnotebook.data.NoteFiles
import io.github.leonmason.gitnotebook.data.NoteIndex
import io.github.leonmason.gitnotebook.data.NoteSort
import io.github.leonmason.gitnotebook.data.Notebook
import io.github.leonmason.gitnotebook.data.Notebooks
import io.github.leonmason.gitnotebook.data.SyncState
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

/** What the app opens to: the current notebook's notes, or the first steps when there is none yet. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HomeScreen(notebooks: Notebooks, updates: AppUpdates, nav: Navigator) {
    val state by notebooks.state.collectAsStateWithLifecycle()
    val notebook = notebooks.current(state)
    if (notebook != null) {
        NotesHome(notebooks, updates, nav, notebook, state.notebooks, state.noteSort, state.showHiddenFiles)
        return
    }
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("记特", fontWeight = FontWeight.SemiBold) },
                actions = { AppMenu(updates, nav) },
            )
        },
    ) { padding ->
        if (state.accounts.isEmpty()) {
            Welcome(Modifier.padding(padding)) { nav.push(Screen.AddAccount) }
        } else {
            EmptyState(
                title = "还没有笔记本",
                body = "笔记本就像一个文件夹，里面可以放很多篇笔记。\n新建一个，或者用账号里已有的。",
                modifier = Modifier.padding(padding),
            ) {
                ExtendedFloatingActionButton(
                    onClick = { nav.push(Screen.NewNotebook) },
                    icon = { Icon(Icons.Default.Add, contentDescription = null) },
                    text = { Text("添加笔记本") },
                )
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun NotesHome(
    notebooks: Notebooks,
    updates: AppUpdates,
    nav: Navigator,
    notebook: Notebook,
    all: List<Notebook>,
    sort: NoteSort,
    showHidden: Boolean,
) {
    val syncStates by notebooks.syncStates.collectAsStateWithLifecycle()
    val syncState = syncStates[notebook.id]
    val root = notebooks.dir(notebook)
    val folder = nav.homeFolder[notebook.id].orEmpty()
    val drawer = rememberDrawerState(DrawerValue.Closed)
    val snackbar = remember { SnackbarHostState() }
    val scope = rememberCoroutineScope()

    var refresh by remember { mutableIntStateOf(0) }
    var notes by remember { mutableStateOf<List<NoteIndex.Note>?>(null) }
    var tree by remember { mutableStateOf<List<NoteIndex.Entry>>(emptyList()) }
    var total by remember { mutableIntStateOf(0) }
    var conflictCount by remember { mutableIntStateOf(0) }

    var creatingNote by remember { mutableStateOf(false) }
    var creatingFolder by remember { mutableStateOf(false) }
    var renaming by remember { mutableStateOf<File?>(null) }
    var deleting by remember { mutableStateOf<File?>(null) }

    LaunchedEffect(notebook.id, folder, sort, showHidden, refresh, syncState) {
        if (syncState == SyncState.Running) return@LaunchedEffect
        withContext(Dispatchers.IO) {
            // A folder that was renamed or deleted elsewhere (e.g. by a sync) falls back to all notes.
            if (folder.isNotEmpty() && !File(root, folder).isDirectory) {
                nav.homeFolder.remove(notebook.id)
                return@withContext
            }
            val shown = NoteIndex.notes(root, sort, folder, showHidden)
            notes = shown
            tree = NoteIndex.tree(root, showHidden)
            total = if (folder.isEmpty()) shown.size else NoteIndex.notes(root, sort, showHidden = showHidden).size
        }
        conflictCount = notebooks.conflicts(notebook).size
    }
    SyncMessages(notebooks, syncStates, snackbar)

    fun showFolder(path: String) {
        nav.homeFolder[notebook.id] = path
        scope.launch { drawer.close() }
    }

    // A file picked in the file list: notes and text open in the editor, pictures in the viewer.
    fun openFile(path: String) {
        scope.launch { drawer.close() }
        val file = File(root, path)
        when {
            NoteAssets.isImage(file) -> nav.push(Screen.Image(notebook.id, path))
            NoteFiles.isEditable(file) -> nav.push(Screen.Editor(notebook.id, path))
            else -> scope.launch { snackbar.showSnackbar("这种文件暂时不能在手机上打开") }
        }
    }

    BackHandler(enabled = drawer.isOpen) { scope.launch { drawer.close() } }

    ModalNavigationDrawer(
        drawerState = drawer,
        drawerContent = {
            FileListDrawer(
                notebookName = notebook.name,
                total = total,
                tree = tree,
                selected = folder,
                expanded = nav.expandedFolders[notebook.id].orEmpty(),
                onToggle = { path ->
                    val open = nav.expandedFolders[notebook.id].orEmpty()
                    nav.expandedFolders[notebook.id] = if (path in open) open - path else open + path
                },
                onSelectFolder = ::showFolder,
                onOpenFile = ::openFile,
                onNewFolder = { creatingFolder = true },
                onHistory = { path ->
                    scope.launch { drawer.close() }
                    nav.push(Screen.History(notebook.id, path))
                },
                onRename = { renaming = File(root, it) },
                onDelete = { deleting = File(root, it) },
            )
        },
    ) {
        Scaffold(
            topBar = {
                TopAppBar(
                    navigationIcon = {
                        IconButton(onClick = { scope.launch { drawer.open() } }) {
                            Icon(Icons.Default.Menu, contentDescription = "目录")
                        }
                    },
                    title = {
                        NotebookSwitcher(notebook, all, onSwitch = { notebooks.setCurrent(it.id) }, onManage = { nav.push(Screen.Notebooks) })
                    },
                    actions = {
                        SyncButton(syncState == SyncState.Running) { notebooks.startSync(notebook) }
                        AppMenu(updates, nav)
                    },
                )
            },
            floatingActionButton = {
                ExtendedFloatingActionButton(
                    onClick = { creatingNote = true },
                    icon = { Icon(Icons.Default.Add, contentDescription = null) },
                    text = { Text("新建笔记") },
                )
            },
            snackbarHost = { SnackbarHost(snackbar) },
        ) { padding ->
            val list = notes
            LazyColumn(
                contentPadding = PaddingValues(
                    top = padding.calculateTopPadding(),
                    bottom = padding.calculateBottomPadding() + 96.dp,
                ),
            ) {
                item { Box(Modifier.padding(horizontal = 16.dp, vertical = 4.dp)) { SyncStatusLine(notebook, syncState) } }
                if (conflictCount > 0) {
                    item { ConflictsCard(conflictCount) { nav.push(Screen.Conflicts(notebook.id)) } }
                }
                item {
                    ListHeader(
                        title = if (folder.isEmpty()) "全部笔记" else folder.substringAfterLast('/'),
                        count = list?.size,
                        sort = sort,
                        onClearFolder = if (folder.isEmpty()) null else ({ nav.homeFolder.remove(notebook.id) }),
                        onSort = notebooks::setSort,
                    )
                }
                if (list != null && list.isEmpty()) {
                    item {
                        EmptyState(
                            title = if (folder.isEmpty()) "这里还没有笔记" else "这个文件夹里还没有笔记",
                            body = "点右下角「新建笔记」写第一篇。\n写完会自动保存，点右上角的同步按钮就会保存到云端。",
                            modifier = Modifier.padding(top = 48.dp),
                        )
                    }
                }
                items(list.orEmpty(), key = { it.path }) { note ->
                    NoteRow(
                        note = note,
                        // Where the note is, relative to the folder being shown.
                        location = if (folder.isEmpty()) note.folder else note.folder.removePrefix(folder).removePrefix("/"),
                        onOpen = { nav.push(Screen.Editor(notebook.id, note.path)) },
                        onHistory = { nav.push(Screen.History(notebook.id, note.path)) },
                        onRename = { renaming = note.file },
                        onDelete = { deleting = note.file },
                    )
                }
            }
        }
    }

    val here = if (folder.isEmpty()) root else File(root, folder)
    if (creatingNote) {
        TextInputDialog(title = "新建笔记", label = "标题", confirmLabel = "创建", onDismiss = { creatingNote = false }) { name ->
            try {
                val file = NoteFiles.createNote(here, name)
                creatingNote = false
                nav.push(Screen.Editor(notebook.id, NoteFiles.relativePath(root, file)))
                null
            } catch (e: IllegalArgumentException) {
                e.message
            }
        }
    }

    if (creatingFolder) {
        TextInputDialog(
            title = if (folder.isEmpty()) "新建文件夹" else "在「${folder.substringAfterLast('/')}」里新建文件夹",
            label = "文件夹名称",
            confirmLabel = "创建",
            onDismiss = { creatingFolder = false },
        ) { name ->
            try {
                val created = NoteFiles.createFolder(here, name)
                creatingFolder = false
                if (folder.isNotEmpty()) {
                    nav.expandedFolders[notebook.id] = nav.expandedFolders[notebook.id].orEmpty() + folder
                }
                showFolder(NoteFiles.relativePath(root, created))
                refresh++
                null
            } catch (e: IllegalArgumentException) {
                e.message
            }
        }
    }

    renaming?.let { file ->
        TextInputDialog(
            title = "重命名",
            label = "新名称",
            initial = if (file.isDirectory) file.name else file.nameWithoutExtension,
            onDismiss = { renaming = null },
        ) { name ->
            try {
                val old = NoteFiles.relativePath(root, file)
                val wasFolder = file.isDirectory
                val renamed = NoteFiles.rename(file, name)
                renaming = null
                // Keep showing the renamed folder (or the folder inside it).
                if (wasFolder && (folder == old || folder.startsWith("$old/"))) {
                    nav.homeFolder[notebook.id] = NoteFiles.relativePath(root, renamed) + folder.removePrefix(old)
                }
                notebooks.commitInBackground(notebook)
                refresh++
                null
            } catch (e: IllegalArgumentException) {
                e.message
            }
        }
    }

    deleting?.let { file ->
        val isFolder = file.isDirectory
        ConfirmDialog(
            title = "删除「${if (isFolder) file.name else file.nameWithoutExtension}」？",
            text = if (isFolder) {
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
                notebooks.withLock(notebook) { file.deleteRecursively() }
                notebooks.commit(notebook)
                refresh++
            }
        }
    }
}

/** The notebook name in the top bar; tapping it lists the other notebooks and the way to manage them. */
@Composable
private fun NotebookSwitcher(current: Notebook, all: List<Notebook>, onSwitch: (Notebook) -> Unit, onManage: () -> Unit) {
    var open by remember { mutableStateOf(false) }
    Box {
        Row(Modifier.clickable { open = true }, verticalAlignment = Alignment.CenterVertically) {
            Text(current.name, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, fill = false))
            Icon(Icons.Default.ArrowDropDown, contentDescription = "切换笔记本")
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            all.forEach { notebook ->
                DropdownMenuItem(
                    text = { Text(notebook.name, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                    leadingIcon = {
                        if (notebook.id == current.id) Icon(Icons.Default.Check, contentDescription = null) else Spacer(Modifier.size(24.dp))
                    },
                    onClick = {
                        open = false
                        onSwitch(notebook)
                    },
                )
            }
            HorizontalDivider()
            DropdownMenuItem(
                text = { Text("管理笔记本…") },
                leadingIcon = { Icon(Icons.Outlined.Settings, contentDescription = null) },
                onClick = {
                    open = false
                    onManage()
                },
            )
        }
    }
}

/** The ⋮ menu: app-wide things that don't belong to a notebook. */
@Composable
private fun AppMenu(updates: AppUpdates, nav: Navigator) {
    var open by remember { mutableStateOf(false) }
    Box {
        IconButton(onClick = { open = true }) { Icon(Icons.Default.MoreVert, contentDescription = "更多") }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            DropdownMenuItem(text = { Text("管理笔记本") }, onClick = {
                open = false
                nav.push(Screen.Notebooks)
            })
            DropdownMenuItem(text = { Text("云端账号") }, onClick = {
                open = false
                nav.push(Screen.Accounts)
            })
            DropdownMenuItem(text = { Text("设置") }, onClick = {
                open = false
                nav.push(Screen.Settings)
            })
            DropdownMenuItem(text = { Text("检查更新") }, onClick = {
                open = false
                updates.checkNow()
            })
            DropdownMenuItem(text = { Text("当前版本 ${updates.currentVersion}") }, onClick = {}, enabled = false)
        }
    }
}

@Composable
private fun ConflictsCard(count: Int, onClick: () -> Unit) {
    Card(
        onClick = onClick,
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.tertiaryContainer,
            contentColor = MaterialTheme.colorScheme.onTertiaryContainer,
        ),
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
    ) {
        Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Outlined.Info, contentDescription = null)
            Spacer(Modifier.size(12.dp))
            Column {
                Text("有 $count 篇笔记在两个地方都改过", style = MaterialTheme.typography.titleSmall)
                Text("已自动保留较新的版本。点这里查看，也可以换回另一个版本。", style = MaterialTheme.typography.bodySmall)
            }
        }
    }
}

/** "全部笔记 · 23 篇" (or the chosen folder) and the sort order. */
@Composable
private fun ListHeader(title: String, count: Int?, sort: NoteSort, onClearFolder: (() -> Unit)?, onSort: (NoteSort) -> Unit) {
    var open by remember { mutableStateOf(false) }
    Row(
        Modifier.fillMaxWidth().padding(start = 16.dp, end = 4.dp, top = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            if (count == null) title else "$title · $count 篇",
            style = MaterialTheme.typography.titleSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f),
        )
        if (onClearFolder != null) {
            Text(
                "看全部",
                style = MaterialTheme.typography.labelLarge,
                color = MaterialTheme.colorScheme.primary,
                modifier = Modifier.clickable(onClick = onClearFolder).padding(8.dp),
            )
        }
        Box {
            Row(
                Modifier.clickable { open = true }.padding(8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(Icons.AutoMirrored.Filled.Sort, contentDescription = null, modifier = Modifier.size(18.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
                Spacer(Modifier.width(4.dp))
                Text(sort.shortLabel, style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
                NoteSort.entries.forEach { option ->
                    DropdownMenuItem(
                        text = { Text(option.label) },
                        leadingIcon = {
                            if (option == sort) Icon(Icons.Default.Check, contentDescription = null) else Spacer(Modifier.size(24.dp))
                        },
                        onClick = {
                            open = false
                            onSort(option)
                        },
                    )
                }
            }
        }
    }
}

private val NoteSort.shortLabel
    get() = when (this) {
        NoteSort.MODIFIED_DESC -> "最近修改"
        NoteSort.MODIFIED_ASC -> "最早修改"
        NoteSort.TITLE_ASC -> "标题 A→Z"
        NoteSort.TITLE_DESC -> "标题 Z→A"
    }

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun NoteRow(
    note: NoteIndex.Note,
    location: String,
    onOpen: () -> Unit,
    onHistory: () -> Unit,
    onRename: () -> Unit,
    onDelete: () -> Unit,
) {
    var menu by remember { mutableStateOf(false) }
    Box {
        Column(
            Modifier
                .fillMaxWidth()
                .combinedClickable(onClick = onOpen, onLongClick = { menu = true })
                .padding(horizontal = 16.dp, vertical = 10.dp),
        ) {
            Text(note.title, style = MaterialTheme.typography.titleMedium, maxLines = 1, overflow = TextOverflow.Ellipsis)
            if (note.preview.isNotEmpty()) {
                Text(
                    note.preview,
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            Text(
                if (location.isEmpty()) friendlyTime(note.modified) else "$location · ${friendlyTime(note.modified)}",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.outline,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            DropdownMenuItem(text = { Text("历史版本") }, onClick = {
                menu = false
                onHistory()
            })
            DropdownMenuItem(text = { Text("重命名") }, onClick = {
                menu = false
                onRename()
            })
            DropdownMenuItem(text = { Text("删除") }, onClick = {
                menu = false
                onDelete()
            })
        }
        HorizontalDivider(Modifier.align(Alignment.BottomStart).padding(start = 16.dp), color = MaterialTheme.colorScheme.surfaceVariant)
    }
}

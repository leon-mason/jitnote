package io.github.leonmason.jitnote.ui

import androidx.compose.foundation.clickable
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
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Sort
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.outlined.CreateNewFolder
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExtendedFloatingActionButton
import androidx.compose.material3.HorizontalDivider
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
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.github.leonmason.jitnote.data.AppUpdates
import io.github.leonmason.jitnote.data.FileTree
import io.github.leonmason.jitnote.data.NoteAssets
import io.github.leonmason.jitnote.data.NoteFiles
import io.github.leonmason.jitnote.data.NoteIndex
import io.github.leonmason.jitnote.data.NoteSort
import io.github.leonmason.jitnote.data.Notebook
import io.github.leonmason.jitnote.data.Notebooks
import io.github.leonmason.jitnote.data.SyncState
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** What the app opens to: the current notebook's file tree, or the first steps when there is none yet. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HomeScreen(notebooks: Notebooks, updates: AppUpdates, nav: Navigator) {
    val state by notebooks.state.collectAsStateWithLifecycle()
    val notebook = notebooks.current(state)
    if (notebook != null) {
        NotesHome(notebooks, updates, nav, notebook, state.notebooks, state.fileSort, state.showHiddenFiles, state.expandedFolders[notebook.id].orEmpty())
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
    expanded: Set<String>,
) {
    val syncStates by notebooks.syncStates.collectAsStateWithLifecycle()
    val syncState = syncStates[notebook.id]
    val root = notebooks.dir(notebook)
    val snackbar = remember { SnackbarHostState() }
    val scope = rememberCoroutineScope()

    // Back at the file tree: the next note opens in the default mode again.
    LaunchedEffect(Unit) { nav.editorMode.clear() }

    var refresh by remember { mutableIntStateOf(0) }

    // Kept in the Navigator: opening a note discards this screen's remembered state, and coming back
    // must neither flash empty nor lose the scroll position.
    val tree = nav.trees[notebook.id]
    val conflictCount = nav.conflictCounts[notebook.id] ?: 0
    val listState = nav.treeScroll.getOrPut(notebook.id) { LazyListState() }
    val highlighted = nav.highlighted[notebook.id].orEmpty()

    // The folders in the dialogs below are chosen when they open: the highlighted one, or the one long-pressed.
    var creatingNoteIn by remember { mutableStateOf<String?>(null) }
    var creatingFolderIn by remember { mutableStateOf<String?>(null) }
    var renaming by remember { mutableStateOf<File?>(null) }
    var deleting by remember { mutableStateOf<File?>(null) }

    LaunchedEffect(notebook.id, sort, showHidden, refresh, syncState) {
        if (syncState == SyncState.Running) return@LaunchedEffect
        nav.trees[notebook.id] = withContext(Dispatchers.IO) { NoteIndex.tree(root, sort, showHidden) }
    }
    // Separate from the tree walk so a slow walk doesn't delay the card. While a sync runs the last
    // known count stays (the sync holds the notebook's lock, so reading now would only wait).
    LaunchedEffect(notebook.id, refresh, syncState) {
        if (syncState == SyncState.Running) return@LaunchedEffect
        nav.conflictCounts[notebook.id] = notebooks.conflicts(notebook).size
    }
    SyncMessages(notebooks, syncStates, snackbar)

    fun setExpanded(paths: Set<String>) {
        if (paths != expanded) notebooks.setExpandedFolders(notebook.id, paths)
    }

    // A file picked in the tree: notes and text open in the editor, pictures in the viewer,
    // and anything else on a page that hands it to the phone's default app.
    fun openFile(path: String) {
        val file = File(root, path)
        when {
            NoteAssets.isImage(file) -> nav.push(Screen.Image(notebook.id, path))
            NoteFiles.isEditable(file) -> nav.push(Screen.Editor(notebook.id, path))
            else -> nav.push(Screen.ExternalFile(notebook.id, path))
        }
    }

    fun onRowClick(entry: NoteIndex.Entry) {
        if (!entry.isFolder) {
            nav.highlighted[notebook.id] = entry.path
            openFile(entry.path)
        } else if (entry.path in expanded) {
            setExpanded(expanded - entry.path)
            nav.highlighted[notebook.id] = FileTree.parent(entry.path)
        } else {
            setExpanded(expanded + entry.path)
            nav.highlighted[notebook.id] = entry.path
        }
    }

    // New things go in the highlighted folder, or next to the highlighted file.
    val here = FileTree.currentFolder(tree.orEmpty(), highlighted)

    Scaffold(
        topBar = {
            TopAppBar(
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
                onClick = { creatingNoteIn = here },
                icon = { Icon(Icons.Default.Add, contentDescription = null) },
                text = { Text("新建笔记") },
            )
        },
        snackbarHost = { SnackbarHost(snackbar) },
    ) { padding ->
        LazyColumn(
            state = listState,
            contentPadding = PaddingValues(
                top = padding.calculateTopPadding(),
                bottom = padding.calculateBottomPadding() + 96.dp,
            ),
            // A tap on the empty space below the rows clears the highlight, so a new note can go in the root.
            modifier = Modifier.fillMaxSize().clickable(interactionSource = null, indication = null) { nav.highlighted.remove(notebook.id) },
        ) {
            item { Box(Modifier.padding(horizontal = 16.dp, vertical = 4.dp)) { SyncStatusLine(notebook, syncState) } }
            if (conflictCount > 0) {
                item { ConflictsCard(conflictCount) { nav.push(Screen.Conflicts(notebook.id)) } }
            }
            item { TreeHeader(sort, onSort = notebooks::setFileSort, onNewFolder = { creatingFolderIn = here }) }
            if (tree != null && tree.isEmpty()) {
                item {
                    EmptyState(
                        title = "这里还没有笔记",
                        body = "点右下角「新建笔记」写第一篇。\n写完会自动保存，点右上角的同步按钮就会保存到云端。",
                        modifier = Modifier.padding(top = 48.dp),
                    )
                }
            }
            items(FileTree.visibleRows(tree.orEmpty(), expanded), key = { it.entry.path }) { row ->
                val path = row.entry.path
                FileTreeRow(
                    row = row,
                    isExpanded = path in expanded,
                    isHighlighted = path == highlighted,
                    onClick = { onRowClick(row.entry) },
                    onHistory = { nav.push(Screen.History(notebook.id, path)) },
                    onRename = { renaming = File(root, path) },
                    onDelete = { deleting = File(root, path) },
                    onNewNoteHere = { creatingNoteIn = path },
                    onNewFolderHere = { creatingFolderIn = path },
                )
            }
        }
    }

    creatingNoteIn?.let { folder ->
        TextInputDialog(
            title = if (folder.isEmpty()) "新建笔记" else "在「${folder.substringAfterLast('/')}」里新建笔记",
            label = "标题",
            confirmLabel = "创建",
            onDismiss = { creatingNoteIn = null },
        ) { name ->
            try {
                val file = NoteFiles.createNote(if (folder.isEmpty()) root else File(root, folder), name)
                val path = NoteFiles.relativePath(root, file)
                creatingNoteIn = null
                setExpanded(expanded + FileTree.ancestors(path))
                nav.highlighted[notebook.id] = path
                nav.push(Screen.Editor(notebook.id, path, startEditing = true))
                null
            } catch (e: IllegalArgumentException) {
                e.message
            }
        }
    }

    creatingFolderIn?.let { folder ->
        TextInputDialog(
            title = if (folder.isEmpty()) "新建文件夹" else "在「${folder.substringAfterLast('/')}」里新建文件夹",
            label = "文件夹名称",
            confirmLabel = "创建",
            onDismiss = { creatingFolderIn = null },
        ) { name ->
            try {
                val created = NoteFiles.createFolder(if (folder.isEmpty()) root else File(root, folder), name)
                val path = NoteFiles.relativePath(root, created)
                creatingFolderIn = null
                setExpanded(expanded + FileTree.ancestors(path))
                nav.highlighted[notebook.id] = path
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
                val renamed = NoteFiles.rename(file, name)
                val new = NoteFiles.relativePath(root, renamed)
                renaming = null
                setExpanded(FileTree.renamed(expanded, old, new))
                nav.highlighted[notebook.id] = FileTree.moved(highlighted, old, new)
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
            val path = NoteFiles.relativePath(root, file)
            deleting = null
            setExpanded(FileTree.removed(expanded, path))
            // The highlight falls back to the folder that held what was deleted.
            if (highlighted == path || highlighted.startsWith("$path/")) nav.highlighted[notebook.id] = FileTree.parent(path)
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

/** The sort order and the way to a new folder; both act on the current location. */
@Composable
private fun TreeHeader(sort: NoteSort, onSort: (NoteSort) -> Unit, onNewFolder: () -> Unit) {
    var open by remember { mutableStateOf(false) }
    Row(
        Modifier.fillMaxWidth().padding(start = 8.dp, end = 4.dp, top = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
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
        Spacer(Modifier.weight(1f))
        IconButton(onClick = onNewFolder) {
            Icon(Icons.Outlined.CreateNewFolder, contentDescription = "新建文件夹", tint = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

private val NoteSort.shortLabel
    get() = when (this) {
        NoteSort.MODIFIED_DESC -> "最近修改"
        NoteSort.MODIFIED_ASC -> "最早修改"
        NoteSort.TITLE_ASC -> "名称 A→Z"
        NoteSort.TITLE_DESC -> "名称 Z→A"
    }

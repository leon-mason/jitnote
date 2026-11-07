package io.github.leonmason.jitnote.ui

import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.scrollBy
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
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
import androidx.compose.material3.AlertDialog
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
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInWindow
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.github.leonmason.jitnote.data.AppUpdates
import io.github.leonmason.jitnote.data.BrokenImageCheck
import io.github.leonmason.jitnote.data.FileTree
import io.github.leonmason.jitnote.data.NoteAssets
import io.github.leonmason.jitnote.data.NoteFiles
import io.github.leonmason.jitnote.data.NoteIndex
import io.github.leonmason.jitnote.data.NoteSort
import io.github.leonmason.jitnote.data.Notebook
import io.github.leonmason.jitnote.data.Notebooks
import io.github.leonmason.jitnote.data.SyncState
import java.io.File
import kotlin.math.roundToInt
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
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
    val unsynced by notebooks.unsynced.collectAsStateWithLifecycle()
    val root = notebooks.dir(notebook)
    val snackbar = remember { SnackbarHostState() }
    val scope = rememberCoroutineScope()

    // Back at the file tree: the next note opens in the default mode again.
    LaunchedEffect(Unit) { nav.editorMode.clear() }

    var refresh by remember { mutableIntStateOf(0) }

    // Kept in the Navigator: opening a note discards this screen's remembered state, and coming back
    // must neither flash empty nor lose the scroll position.
    val tree = nav.trees[notebook.id]
    val listState = nav.treeScroll.getOrPut(notebook.id) { LazyListState() }
    val highlighted = nav.highlighted[notebook.id].orEmpty()

    // The folders in the dialogs below are chosen when they open: the highlighted one, or the one long-pressed.
    var creatingNoteIn by remember { mutableStateOf<String?>(null) }
    var creatingFolderIn by remember { mutableStateOf<String?>(null) }
    var renaming by remember { mutableStateOf<File?>(null) }
    var deleting by remember { mutableStateOf<File?>(null) }
    // The notebook-relative path being chosen a folder for by "移动到…".
    var moving by remember { mutableStateOf<String?>(null) }
    // Why a move did not happen, or what the user has to confirm before it does.
    var moveNotice by remember { mutableStateOf<MoveNotice?>(null) }
    // A row being dragged, and where the finger is, relative to the list.
    var dragging by remember { mutableStateOf<String?>(null) }
    var finger by remember { mutableStateOf<Offset?>(null) }
    var listOrigin by remember { mutableStateOf(Offset.Zero) }

    LaunchedEffect(notebook.id, sort, showHidden, refresh, syncState) {
        if (syncState == SyncState.Running) return@LaunchedEffect
        nav.trees[notebook.id] = withContext(Dispatchers.IO) { NoteIndex.tree(root, sort, showHidden) }
    }
    LaunchedEffect(notebook.id, refresh) { notebooks.refreshUnsynced(notebook) }
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

    // Checks a move before it happens (design.md「首页」): the name must be free in the target folder, and if
    // notes would lose their pictures the user is asked first. The picker and dragging both come through here.
    fun performMove(source: String, folder: String) {
        scope.launch {
            try {
                // Under the notebook's lock, so it can't happen in the middle of a sync.
                val moved = notebooks.withLock(notebook) { NoteFiles.move(File(root, source), if (folder.isEmpty()) root else File(root, folder)) }
                val new = NoteFiles.relativePath(root, moved)
                // The target folder opens (it is above the new path), so the item is seen where it landed.
                setExpanded(FileTree.renamed(expanded, source, new) + FileTree.ancestors(new))
                nav.highlighted[notebook.id] = new
                refresh++
                notebooks.refreshUnsynced(notebook)
            } catch (e: IllegalArgumentException) {
                moveNotice = MoveNotice.Failed(e.message ?: "移动失败")
            }
        }
    }

    fun requestMove(source: String, folder: String) {
        if (!FileTree.canMove(source, folder)) return
        if (File(if (folder.isEmpty()) root else File(root, folder), source.substringAfterLast('/')).exists()) {
            moveNotice = MoveNotice.Failed("目标文件夹里已有同名文件")
            return
        }
        scope.launch {
            val broken = withContext(Dispatchers.IO) { BrokenImageCheck.notes(root, source, folder) }
            if (broken.isEmpty()) performMove(source, folder) else moveNotice = MoveNotice.BrokenImages(broken.size, source, folder)
        }
    }

    // The row under the finger while dragging: item offsets are in content coordinates, the finger in the list's own,
    // and the content starts after the top padding (viewportStartOffset is minus that padding).
    val layout = listState.layoutInfo
    val rowUnderFinger = finger?.takeIf { dragging != null }?.let { point ->
        val contentY = point.y + layout.viewportStartOffset
        layout.visibleItemsInfo.firstOrNull { it.key is String && contentY >= it.offset && contentY < it.offset + it.size }?.key as? String
    }
    // Where a row dropped now would go: a folder itself, a file's folder, the root for empty space. Null when that does nothing.
    val dropFolder = dragging?.let { source ->
        finger?.let { FileTree.currentFolder(tree.orEmpty(), rowUnderFinger.orEmpty()).takeIf { folder -> FileTree.canMove(source, folder) } }
    }

    // A dragged row opens a closed folder after resting on it for a second (design.md「首页」).
    val expandedNow by rememberUpdatedState(expanded)
    val resting = rowUnderFinger?.takeIf { path -> FileTree.find(tree.orEmpty(), path)?.isFolder == true && path !in expanded }
    LaunchedEffect(resting) {
        if (resting != null) {
            delay(1000)
            notebooks.setExpandedFolders(notebook.id, expandedNow + resting)
        }
    }

    // Dragging near the top or bottom edge of the list scrolls it.
    val edge = with(LocalDensity.current) { 56.dp.toPx() }
    val scrollDirection = finger?.takeIf { dragging != null }?.let { point ->
        when {
            point.y < layout.beforeContentPadding + edge -> -1
            point.y > layout.viewportSize.height - edge -> 1
            else -> 0
        }
    } ?: 0
    LaunchedEffect(scrollDirection) {
        while (scrollDirection != 0) {
            listState.scrollBy(scrollDirection * 18f)
            delay(16)
        }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = {
                    NotebookSwitcher(notebook, all, onSwitch = { notebooks.setCurrent(it.id) }, onManage = { nav.push(Screen.Notebooks) })
                },
                actions = {
                    SyncButton(syncState == SyncState.Running, notebook.id in unsynced) { notebooks.startSync(notebook) }
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
        Box(
            Modifier
                .fillMaxSize()
                .onGloballyPositioned { listOrigin = it.positionInWindow() }
                // Dropping on empty space moves to the notebook root, so the whole list is the target then.
                .then(if (dropFolder == "") Modifier.border(2.dp, MaterialTheme.colorScheme.primary) else Modifier),
        ) {
        LazyColumn(
            state = listState,
            contentPadding = PaddingValues(
                top = padding.calculateTopPadding(),
                bottom = padding.calculateBottomPadding() + 96.dp,
            ),
            // A tap on the empty space below the rows clears the highlight, so a new note can go in the root.
            modifier = Modifier.fillMaxSize().clickable(interactionSource = null, indication = null) { nav.highlighted.remove(notebook.id) },
        ) {
            item { Box(Modifier.padding(horizontal = 16.dp, vertical = 4.dp)) { SyncStatusLine(notebook, syncState, notebook.id in unsynced) } }
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
                    onMove = { moving = path },
                    onDelete = { deleting = File(root, path) },
                    onNewNoteHere = { creatingNoteIn = path },
                    onNewFolderHere = { creatingFolderIn = path },
                    isDragged = dragging == path,
                    isDropTarget = dropFolder == path,
                    onDragStart = { dragging = path },
                    onDragMove = { finger = it - listOrigin },
                    onDragEnd = {
                        val source = dragging
                        val target = dropFolder
                        dragging = null
                        finger = null
                        if (source != null && target != null) requestMove(source, target)
                    },
                    onDragCancel = {
                        dragging = null
                        finger = null
                    },
                )
            }
        }
        // The dragged row's name follows the finger.
        dragging?.let { source ->
            finger?.let { point ->
                val lift = with(LocalDensity.current) { 48.dp.toPx() }
                Surface(
                    shape = RoundedCornerShape(16.dp),
                    tonalElevation = 6.dp,
                    shadowElevation = 6.dp,
                    modifier = Modifier.offset { IntOffset(24.dp.roundToPx(), (point.y - lift).roundToInt()) },
                ) {
                    Text(source.substringAfterLast('/'), modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp), maxLines = 1)
                }
            }
        }
        }
    }

    moving?.let { source ->
        val isFolder = File(root, source).isDirectory
        MoveTargetSheet(
            name = if (isFolder) source.substringAfterLast('/') else File(source).nameWithoutExtension,
            source = source,
            tree = tree.orEmpty(),
            onDismiss = { moving = null },
            onMove = { folder ->
                moving = null
                requestMove(source, folder)
            },
        )
    }

    moveNotice?.let { notice ->
        when (notice) {
            is MoveNotice.Failed -> AlertDialog(
                onDismissRequest = { moveNotice = null },
                title = { Text("无法移动") },
                text = { Text(notice.message) },
                confirmButton = { TextButton(onClick = { moveNotice = null }) { Text("好") } },
            )
            is MoveNotice.BrokenImages -> ConfirmDialog(
                title = "移动后图片会找不到",
                text = "移动后，${notice.count} 篇笔记里的图片会找不到",
                confirmLabel = "仍然移动",
                onDismiss = { moveNotice = null },
            ) {
                moveNotice = null
                performMove(notice.source, notice.folder)
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
                // Nothing is committed between syncs, so keep a version of what is about to disappear.
                notebooks.keepVersion(notebook, listOf(path))
                notebooks.withLock(notebook) { file.deleteRecursively() }
                refresh++
            }
        }
    }
}

/** Why a move did not happen, or what the user has to confirm before it does. */
private sealed interface MoveNotice {
    class Failed(val message: String) : MoveNotice

    /** [count] notes would lose pictures; going ahead moves [source] into [folder]. */
    class BrokenImages(val count: Int, val source: String, val folder: String) : MoveNotice
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

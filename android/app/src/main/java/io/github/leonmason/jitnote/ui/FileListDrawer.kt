package io.github.leonmason.jitnote.ui

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.Notes
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.outlined.CreateNewFolder
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material.icons.outlined.Image
import androidx.compose.material.icons.automirrored.outlined.InsertDriveFile
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalDrawerSheet
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import io.github.leonmason.jitnote.data.NoteAssets
import io.github.leonmason.jitnote.data.NoteFiles
import io.github.leonmason.jitnote.data.NoteIndex
import java.io.File

/**
 * The side panel, called 文件列表 like Obsidian's file explorer: every file and folder with its full
 * name. Picking a folder narrows the note list to it; picking a file opens it. Long-press for more.
 */
@Composable
fun FileListDrawer(
    notebookName: String,
    total: Int,
    tree: List<NoteIndex.Entry>,
    selected: String,
    expanded: Set<String>,
    onToggle: (String) -> Unit,
    onSelectFolder: (String) -> Unit,
    onOpenFile: (String) -> Unit,
    onNewFolder: () -> Unit,
    onHistory: (String) -> Unit,
    onRename: (String) -> Unit,
    onDelete: (String) -> Unit,
) {
    ModalDrawerSheet {
        Text(
            notebookName,
            style = MaterialTheme.typography.titleMedium,
            fontWeight = FontWeight.SemiBold,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.padding(start = 24.dp, end = 16.dp, top = 20.dp, bottom = 8.dp),
        )
        LazyColumn(Modifier.weight(1f)) {
            item {
                DrawerRow(
                    icon = Icons.AutoMirrored.Outlined.Notes,
                    name = "全部笔记",
                    count = total,
                    depth = 0,
                    isSelected = selected.isEmpty(),
                    expandable = false,
                    isExpanded = false,
                    onToggle = {},
                    onClick = { onSelectFolder("") },
                )
            }
            item {
                Text(
                    "文件列表",
                    style = MaterialTheme.typography.labelLarge,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(start = 28.dp, top = 16.dp, bottom = 4.dp),
                )
            }
            items(tree, key = { it.path }) { entry ->
                EntryRow(entry, 0, selected, expanded, onToggle, onSelectFolder, onOpenFile, onHistory, onRename, onDelete)
            }
        }
        HorizontalDivider()
        TextButton(onClick = onNewFolder, modifier = Modifier.padding(horizontal = 12.dp, vertical = 4.dp)) {
            Icon(Icons.Outlined.CreateNewFolder, contentDescription = null)
            Spacer(Modifier.width(8.dp))
            Text("新建文件夹")
        }
    }
}

/** One file, or one folder and, when open, what is inside it. */
@Composable
private fun EntryRow(
    entry: NoteIndex.Entry,
    depth: Int,
    selected: String,
    expanded: Set<String>,
    onToggle: (String) -> Unit,
    onSelectFolder: (String) -> Unit,
    onOpenFile: (String) -> Unit,
    onHistory: (String) -> Unit,
    onRename: (String) -> Unit,
    onDelete: (String) -> Unit,
) {
    var menu by remember { mutableStateOf(false) }
    // The chosen folder's parents open by themselves, so the selection is always visible.
    val isExpanded = entry.isFolder && (entry.path in expanded || selected.startsWith(entry.path + "/"))
    val file = File(entry.name)
    Box {
        DrawerRow(
            icon = when {
                entry.isFolder -> Icons.Outlined.Folder
                NoteAssets.isImage(file) -> Icons.Outlined.Image
                NoteFiles.isTextName(entry.name) -> Icons.Outlined.Description
                else -> Icons.AutoMirrored.Outlined.InsertDriveFile
            },
            name = entry.name,
            count = if (entry.isFolder) entry.noteCount else null,
            depth = depth,
            isSelected = entry.isFolder && selected == entry.path,
            expandable = entry.children.isNotEmpty(),
            isExpanded = isExpanded,
            onToggle = { onToggle(entry.path) },
            onClick = { if (entry.isFolder) onSelectFolder(entry.path) else onOpenFile(entry.path) },
            onLongClick = { menu = true },
        )
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            if (!entry.isFolder && NoteFiles.isTextName(entry.name)) {
                DropdownMenuItem(text = { Text("历史版本") }, onClick = {
                    menu = false
                    onHistory(entry.path)
                })
            }
            DropdownMenuItem(text = { Text("重命名") }, onClick = {
                menu = false
                onRename(entry.path)
            })
            DropdownMenuItem(text = { Text("删除") }, onClick = {
                menu = false
                onDelete(entry.path)
            })
        }
    }
    if (isExpanded) {
        entry.children.forEach { child ->
            EntryRow(child, depth + 1, selected, expanded, onToggle, onSelectFolder, onOpenFile, onHistory, onRename, onDelete)
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun DrawerRow(
    icon: ImageVector,
    name: String,
    count: Int?,
    depth: Int,
    isSelected: Boolean,
    expandable: Boolean,
    isExpanded: Boolean,
    onToggle: () -> Unit,
    onClick: () -> Unit,
    onLongClick: (() -> Unit)? = null,
) {
    val colors = MaterialTheme.colorScheme
    val tint = if (isSelected) colors.onSecondaryContainer else colors.onSurfaceVariant
    Row(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = 12.dp, vertical = 1.dp)
            .clip(RoundedCornerShape(24.dp))
            .background(if (isSelected) colors.secondaryContainer else Color.Transparent)
            .combinedClickable(onClick = onClick, onLongClick = onLongClick)
            .padding(start = (depth * 16).dp, end = 16.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (expandable) {
            IconButton(onClick = onToggle, modifier = Modifier.size(40.dp)) {
                Icon(
                    if (isExpanded) Icons.Default.ExpandMore else Icons.Default.ChevronRight,
                    contentDescription = if (isExpanded) "收起" else "展开",
                    tint = tint,
                )
            }
        } else {
            Spacer(Modifier.size(40.dp))
        }
        Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(20.dp))
        Spacer(Modifier.width(12.dp))
        Text(
            name,
            style = MaterialTheme.typography.bodyLarge,
            color = if (isSelected) colors.onSecondaryContainer else colors.onSurface,
            fontWeight = if (isSelected) FontWeight.SemiBold else FontWeight.Normal,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f).padding(vertical = 12.dp),
        )
        if (count != null) Text(count.toString(), style = MaterialTheme.typography.labelMedium, color = tint)
    }
}

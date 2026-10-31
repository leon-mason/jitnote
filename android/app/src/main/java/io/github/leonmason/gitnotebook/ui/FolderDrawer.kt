package io.github.leonmason.gitnotebook.ui

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
import io.github.leonmason.gitnotebook.data.NoteIndex

/**
 * The side panel with the notebook's folders. Picking a folder narrows the note list to it;
 * long-press a folder to rename or delete it.
 */
@Composable
fun FolderDrawer(
    notebookName: String,
    total: Int,
    tree: List<NoteIndex.Folder>,
    selected: String,
    expanded: Set<String>,
    onToggle: (String) -> Unit,
    onSelect: (String) -> Unit,
    onNewFolder: () -> Unit,
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
                    onClick = { onSelect("") },
                )
            }
            items(tree, key = { it.path }) { folder ->
                FolderRow(folder, 0, selected, expanded, onToggle, onSelect, onRename, onDelete)
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

/** One folder and, when open, its subfolders. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun FolderRow(
    folder: NoteIndex.Folder,
    depth: Int,
    selected: String,
    expanded: Set<String>,
    onToggle: (String) -> Unit,
    onSelect: (String) -> Unit,
    onRename: (String) -> Unit,
    onDelete: (String) -> Unit,
) {
    var menu by remember { mutableStateOf(false) }
    // The chosen folder's parents open by themselves, so the selection is always visible.
    val isExpanded = folder.path in expanded || selected.startsWith(folder.path + "/")
    Box {
        DrawerRow(
            icon = Icons.Outlined.Folder,
            name = folder.name,
            count = folder.noteCount,
            depth = depth,
            isSelected = selected == folder.path,
            expandable = folder.children.isNotEmpty(),
            isExpanded = isExpanded,
            onToggle = { onToggle(folder.path) },
            onClick = { onSelect(folder.path) },
            onLongClick = { menu = true },
        )
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            DropdownMenuItem(text = { Text("重命名") }, onClick = {
                menu = false
                onRename(folder.path)
            })
            DropdownMenuItem(text = { Text("删除") }, onClick = {
                menu = false
                onDelete(folder.path)
            })
        }
    }
    if (isExpanded) {
        folder.children.forEach { child ->
            FolderRow(child, depth + 1, selected, expanded, onToggle, onSelect, onRename, onDelete)
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun DrawerRow(
    icon: ImageVector,
    name: String,
    count: Int,
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
        Text(count.toString(), style = MaterialTheme.typography.labelMedium, color = tint)
    }
}

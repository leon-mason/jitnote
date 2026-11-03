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
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.InsertDriveFile
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material.icons.outlined.Image
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import io.github.leonmason.jitnote.data.FileTree
import io.github.leonmason.jitnote.data.NoteAssets
import io.github.leonmason.jitnote.data.NoteFiles
import java.io.File

/**
 * One row of the file tree, called 文件列表 like Obsidian's file explorer: a file or folder with its
 * full name. The whole row is tappable; long-press for more.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun FileTreeRow(
    row: FileTree.Row,
    isExpanded: Boolean,
    isHighlighted: Boolean,
    onClick: () -> Unit,
    onHistory: () -> Unit,
    onRename: () -> Unit,
    onDelete: () -> Unit,
    onNewNoteHere: () -> Unit,
    onNewFolderHere: () -> Unit,
) {
    val entry = row.entry
    var menu by remember { mutableStateOf(false) }
    val colors = MaterialTheme.colorScheme
    val tint = if (isHighlighted) colors.onSecondaryContainer else colors.onSurfaceVariant
    val file = File(entry.name)
    Box {
        Row(
            Modifier
                .fillMaxWidth()
                .padding(horizontal = 12.dp, vertical = 1.dp)
                .clip(RoundedCornerShape(24.dp))
                .background(if (isHighlighted) colors.secondaryContainer else Color.Transparent)
                .combinedClickable(onClick = onClick, onLongClick = { menu = true })
                .padding(start = (row.depth * 16).dp, end = 16.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            // The arrow is only a sign of the state: the whole row responds to taps.
            if (entry.isFolder) {
                Icon(
                    if (isExpanded) Icons.Default.ExpandMore else Icons.Default.ChevronRight,
                    contentDescription = if (isExpanded) "已展开" else "已收起",
                    tint = tint,
                    modifier = Modifier.padding(8.dp),
                )
            } else {
                Spacer(Modifier.size(40.dp))
            }
            Icon(
                when {
                    entry.isFolder -> Icons.Outlined.Folder
                    NoteAssets.isImage(file) -> Icons.Outlined.Image
                    NoteFiles.isTextName(entry.name) -> Icons.Outlined.Description
                    else -> Icons.AutoMirrored.Outlined.InsertDriveFile
                },
                contentDescription = null,
                tint = tint,
                modifier = Modifier.size(20.dp),
            )
            Spacer(Modifier.width(12.dp))
            Text(
                entry.name,
                style = MaterialTheme.typography.bodyLarge,
                color = if (isHighlighted) colors.onSecondaryContainer else colors.onSurface,
                fontWeight = if (isHighlighted) FontWeight.SemiBold else FontWeight.Normal,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f).padding(vertical = 12.dp),
            )
            if (entry.isFolder) Text(entry.noteCount.toString(), style = MaterialTheme.typography.labelMedium, color = tint)
        }
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            if (entry.isFolder) {
                DropdownMenuItem(text = { Text("新建笔记") }, onClick = {
                    menu = false
                    onNewNoteHere()
                })
                DropdownMenuItem(text = { Text("新建文件夹") }, onClick = {
                    menu = false
                    onNewFolderHere()
                })
            } else if (!NoteAssets.isImage(file)) {
                DropdownMenuItem(text = { Text("历史版本") }, onClick = {
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

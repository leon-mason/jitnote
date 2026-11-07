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
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.foundation.gestures.detectDragGesturesAfterLongPress
import androidx.compose.ui.layout.LayoutCoordinates
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import io.github.leonmason.jitnote.data.FileTree
import io.github.leonmason.jitnote.data.NoteAssets
import io.github.leonmason.jitnote.data.NoteFiles
import java.io.File

/**
 * One row of the file tree, called 文件列表 like Obsidian's file explorer: a file or folder with its
 * full name. The whole row is tappable. A long press that is let go without moving opens the menu;
 * a long press that moves the finger drags the row instead (design.md「首页」), reporting where the
 * finger is, in window coordinates, so the tree can find the row under it.
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
    onMove: () -> Unit,
    onDelete: () -> Unit,
    onNewNoteHere: () -> Unit,
    onNewFolderHere: () -> Unit,
    isDragged: Boolean,
    isDropTarget: Boolean,
    onDragStart: () -> Unit,
    onDragMove: (Offset) -> Unit,
    onDragEnd: () -> Unit,
    onDragCancel: () -> Unit,
) {
    val entry = row.entry
    var menu by remember { mutableStateOf(false) }
    val colors = MaterialTheme.colorScheme
    val tint = if (isHighlighted) colors.onSecondaryContainer else colors.onSurfaceVariant
    val file = File(entry.name)
    var coordinates by remember { mutableStateOf<LayoutCoordinates?>(null) }
    // The gesture below is set up once, so it reads the callbacks through these.
    val dragStart by rememberUpdatedState(onDragStart)
    val dragMove by rememberUpdatedState(onDragMove)
    val dragEnd by rememberUpdatedState(onDragEnd)
    val dragCancel by rememberUpdatedState(onDragCancel)
    Box {
        Row(
            Modifier
                .fillMaxWidth()
                .alpha(if (isDragged) 0.4f else 1f)
                .padding(horizontal = 12.dp, vertical = 1.dp)
                .clip(RoundedCornerShape(24.dp))
                .background(
                    when {
                        isDropTarget -> colors.primaryContainer
                        isHighlighted -> colors.secondaryContainer
                        else -> Color.Transparent
                    },
                )
                .onGloballyPositioned { coordinates = it }
                // The long press is handled by the gesture below. The empty onLongClick only keeps the finger
                // lifting after it from counting as a tap, and gives the touch of feedback.
                .combinedClickable(onClick = onClick, onLongClick = {})
                .pointerInput(Unit) {
                    var moved = false
                    var travelled = Offset.Zero
                    detectDragGesturesAfterLongPress(
                        onDragStart = {
                            moved = false
                            travelled = Offset.Zero
                        },
                        onDrag = { change, amount ->
                            travelled += amount
                            // A finger always wobbles; only a real move turns the press into a drag.
                            if (!moved && travelled.getDistance() > viewConfiguration.touchSlop) {
                                moved = true
                                dragStart()
                            }
                            if (moved) coordinates?.let { dragMove(it.localToWindow(change.position)) }
                        },
                        onDragEnd = { if (moved) dragEnd() else menu = true },
                        onDragCancel = { if (moved) dragCancel() },
                    )
                }
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
            DropdownMenuItem(text = { Text("移动到…") }, onClick = {
                menu = false
                onMove()
            })
            DropdownMenuItem(text = { Text("删除") }, onClick = {
                menu = false
                onDelete()
            })
        }
    }
}

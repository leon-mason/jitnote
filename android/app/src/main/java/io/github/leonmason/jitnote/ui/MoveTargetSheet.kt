package io.github.leonmason.jitnote.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material.icons.outlined.MenuBook
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import io.github.leonmason.jitnote.data.FileTree
import io.github.leonmason.jitnote.data.NoteIndex

/**
 * The picker behind "移动到…": the notebook root and every folder, to choose where a file or folder goes.
 * It only chooses; checking for a name clash and moving happen on the file tree screen.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MoveTargetSheet(
    name: String,
    /** Notebook-relative path of what moves. */
    source: String,
    tree: List<NoteIndex.Entry>,
    onDismiss: () -> Unit,
    onMove: (String) -> Unit,
) {
    val colors = MaterialTheme.colorScheme
    // Opens on the folder the item is in, so the current place is the first thing seen.
    var expanded by remember { mutableStateOf(FileTree.ancestors(source)) }
    var chosen by remember { mutableStateOf<String?>(null) }
    val rows = FileTree.visibleRows(tree, expanded).filter { it.entry.isFolder }
    val listState = remember { LazyListState() }
    LaunchedEffect(Unit) {
        val here = FileTree.parent(source)
        listState.scrollToItem(if (here.isEmpty()) 0 else rows.indexOfFirst { it.entry.path == here } + 1)
    }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        Column(Modifier.padding(horizontal = 16.dp)) {
            Text("把「$name」移动到", style = MaterialTheme.typography.titleMedium, modifier = Modifier.padding(bottom = 8.dp))
            LazyColumn(state = listState, modifier = Modifier.weight(1f, fill = false)) {
                item { PickerRow("", "笔记本根目录", 0, false, source, chosen == "", expanded, { chosen = it }, {}) }
                items(rows, key = { it.entry.path }) { row ->
                    PickerRow(
                        row.entry.path, row.entry.name, row.depth + 1, row.entry.children.any { it.isFolder },
                        source, chosen == row.entry.path, expanded, { chosen = it },
                        { path -> expanded = if (path in expanded) expanded - path else expanded + path },
                    )
                }
            }
            Row(Modifier.fillMaxWidth().padding(vertical = 12.dp), horizontalArrangement = Arrangement.End) {
                TextButton(onClick = onDismiss) { Text("取消") }
                Button(onClick = { chosen?.let(onMove) }, enabled = chosen != null) { Text("移动") }
            }
        }
    }
}

@Composable
private fun PickerRow(
    path: String,
    label: String,
    depth: Int,
    hasSubfolders: Boolean,
    source: String,
    isChosen: Boolean,
    expanded: Set<String>,
    onChoose: (String) -> Unit,
    onToggle: (String) -> Unit,
) {
    // Where it already is, itself and everything inside it are greyed out (FileTree.canMove).
    val allowed = FileTree.canMove(source, path)
    val colors = MaterialTheme.colorScheme
    Row(
        Modifier
            .fillMaxWidth()
            .padding(vertical = 1.dp)
            .clip(RoundedCornerShape(24.dp))
            .background(if (isChosen && allowed) colors.secondaryContainer else Color.Transparent)
            .alpha(if (allowed) 1f else 0.4f)
            .clickable(enabled = allowed) { onChoose(path) }
            .padding(start = (depth * 16).dp, end = 16.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        // The arrow opens and closes the folder; tapping the name picks it.
        if (hasSubfolders) {
            Icon(
                if (path in expanded) Icons.Default.ExpandMore else Icons.Default.ChevronRight,
                contentDescription = if (path in expanded) "已展开" else "已收起",
                modifier = Modifier.clickable { onToggle(path) }.padding(8.dp),
            )
        } else {
            Spacer(Modifier.size(40.dp))
        }
        Icon(if (path.isEmpty()) Icons.Outlined.MenuBook else Icons.Outlined.Folder, contentDescription = null, modifier = Modifier.size(20.dp))
        Text(
            label,
            style = MaterialTheme.typography.bodyLarge,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f).padding(start = 12.dp, top = 12.dp, bottom = 12.dp),
        )
    }
}

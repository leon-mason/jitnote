package io.github.leonmason.jitnote.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import io.github.leonmason.jitnote.core.ConflictRecord
import io.github.leonmason.jitnote.core.Side
import io.github.leonmason.jitnote.data.NoteFiles
import io.github.leonmason.jitnote.data.Notebooks
import kotlinx.coroutines.launch
import java.io.File

@Composable
fun ConflictsScreen(notebooks: Notebooks, nav: Navigator, screen: Screen.Conflicts) {
    val notebook = notebooks.notebook(screen.notebookId) ?: return
    var records by remember { mutableStateOf<List<ConflictRecord>?>(null) }
    var refresh by remember { mutableIntStateOf(0) }
    var switching by remember { mutableStateOf<ConflictRecord?>(null) }
    val scope = rememberCoroutineScope()
    LaunchedEffect(refresh) { records = notebooks.conflicts(notebook) }

    Scaffold(topBar = { BackTopBar("两边都改过的笔记", onBack = nav::pop) }) { padding ->
        val list = records
        when {
            list == null -> Waiting("正在读取…")
            list.isEmpty() -> EmptyState("都处理好了", "没有需要确认的笔记。", Modifier.padding(padding))
            else -> LazyColumn(contentPadding = padding) {
                item {
                    Text(
                        "这些笔记在这台手机和别的地方（另一台设备或电脑）都被修改过。" +
                            "App 已经自动保留了较新的版本，另一个版本也没有丢，你可以随时换回去。",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(16.dp),
                    )
                }
                items(list, key = { it.path }) { record ->
                    ConflictCard(
                        notebooks = notebooks,
                        notebookId = notebook.id,
                        record = record,
                        onUseOther = { switching = record },
                        onKeep = {
                            scope.launch {
                                notebooks.dismissConflict(notebook, record)
                                refresh++
                            }
                        },
                    )
                }
            }
        }
    }

    switching?.let { record ->
        ConfirmDialog(
            title = "换成另一个版本？",
            text = if (record.otherBlob == null) {
                "另一个版本里这篇笔记已被删除，换过去会删除这篇笔记（历史版本里仍可找回）。"
            } else {
                "当前内容会被另一个版本替换，当前内容仍会留在历史版本里。记得之后点同步。"
            },
            confirmLabel = "换成另一个版本",
            onDismiss = { switching = null },
        ) {
            switching = null
            scope.launch {
                notebooks.useOtherVersion(notebook, record)
                refresh++
            }
        }
    }
}

@Composable
private fun ConflictCard(
    notebooks: Notebooks,
    notebookId: String,
    record: ConflictRecord,
    onUseOther: () -> Unit,
    onKeep: () -> Unit,
) {
    var preview by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    val notebook = notebooks.notebook(notebookId) ?: return
    val keptWhere = if (record.kept == Side.LOCAL) "这台手机" else "云端"
    val otherWhere = if (record.kept == Side.LOCAL) "云端" else "这台手机"

    Card(
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainer),
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp),
    ) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(NoteFiles.Entry(File(record.path), false, 0).title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
            Text("现在用的：${keptWhere}的版本（${timeOrUnknown(record.keptTime)}修改）", style = MaterialTheme.typography.bodyMedium)
            Text(
                if (record.otherBlob == null) "另一个：${otherWhere}把它删除了"
                else "另一个：${otherWhere}的版本（${timeOrUnknown(record.otherTime)}修改）",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            preview?.let {
                Surface(color = MaterialTheme.colorScheme.surface, shape = MaterialTheme.shapes.small) {
                    Text(
                        it.ifBlank { "（空白）" },
                        style = MaterialTheme.typography.bodySmall,
                        modifier = Modifier.heightIn(max = 240.dp).verticalScroll(rememberScrollState()).padding(12.dp),
                    )
                }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                if (record.otherBlob != null && preview == null) {
                    TextButton(onClick = {
                        scope.launch {
                            preview = notebooks.withLock(notebook) {
                                notebooks.git(notebook).readBlob(record.otherBlob).toString(Charsets.UTF_8)
                            }
                        }
                    }) { Text("看看另一个") }
                }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedButton(onClick = onUseOther) { Text("换成另一个") }
                Button(onClick = onKeep) { Text("就用现在的") }
            }
        }
    }
}

private fun timeOrUnknown(millis: Long) = if (millis > 0) friendlyTime(millis) else "未知时间"

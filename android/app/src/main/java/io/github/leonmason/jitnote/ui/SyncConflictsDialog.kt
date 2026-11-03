package io.github.leonmason.jitnote.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.github.leonmason.jitnote.core.NotebookGit
import io.github.leonmason.jitnote.core.PendingConflict
import io.github.leonmason.jitnote.core.Side
import io.github.leonmason.jitnote.data.Notebooks

/** Shows the question a sync asks, over whatever screen is open, until it is answered or cancelled. */
@Composable
fun SyncConflictsDialog(notebooks: Notebooks) {
    val pending by notebooks.pendingSync.collectAsStateWithLifecycle()
    pending?.let { question ->
        // Back counts as cancelling: closing it any other way would leave the sync half done with no way to resume.
        Dialog(
            onDismissRequest = notebooks::cancelPendingSync,
            properties = DialogProperties(usePlatformDefaultWidth = false, dismissOnClickOutside = false),
        ) {
            Surface(Modifier.fillMaxSize()) {
                SyncConflicts(question, onCancel = notebooks::cancelPendingSync, onContinue = notebooks::continueSync)
            }
        }
    }
}

/**
 * The question a sync asks when a note changed both here and elsewhere: which side wins. Nothing has
 * been merged yet; the side that does not win stays in the history.
 */
@Composable
private fun SyncConflicts(
    pending: Notebooks.PendingSync,
    onCancel: () -> Unit,
    onContinue: (Map<String, Side>) -> Unit,
) {
    val choices = remember(pending) { mutableStateMapOf<String, Side>().apply { putAll(pending.choices) } }
    val allChosen = pending.conflicts.all { it.path in choices }

    Column(Modifier.fillMaxSize().padding(top = 24.dp)) {
        Column(Modifier.padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(
                "「${pending.notebook.name}」有 ${pending.conflicts.size} 篇笔记在两个地方都改过",
                style = MaterialTheme.typography.titleLarge,
            )
            Text(
                "请选择每一篇以哪边为准。没选中的那一版不会丢，仍然留在历史版本里。",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedButton(onClick = { pending.conflicts.forEach { choices[it.path] = Side.LOCAL } }) { Text("全部以这台手机为准") }
                OutlinedButton(onClick = { pending.conflicts.forEach { choices[it.path] = Side.REMOTE } }) { Text("全部以云端为准") }
            }
        }
        LazyColumn(Modifier.weight(1f).padding(top = 8.dp)) {
            items(pending.conflicts, key = { it.path }) { conflict ->
                ConflictRow(conflict, choices[conflict.path]) { choices[conflict.path] = it }
                HorizontalDivider()
            }
        }
        Row(
            Modifier.fillMaxWidth().padding(16.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.End),
        ) {
            TextButton(onClick = onCancel) { Text("取消同步") }
            Button(onClick = { onContinue(choices.toMap()) }, enabled = allChosen) { Text("继续同步") }
        }
    }
}

@Composable
private fun ConflictRow(conflict: PendingConflict, choice: Side?, onChoose: (Side) -> Unit) {
    var comparing by remember { mutableStateOf(false) }
    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp)) {
        Text(NotebookGit.title(conflict.path), style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Medium)
        when {
            conflict.local == null -> Note("这台手机上已经把它删除了，云端改过了。")
            conflict.cloud == null -> Note("云端已经把它删除了，这台手机改过了。")
        }
        Row(verticalAlignment = Alignment.CenterVertically) {
            Choice("这台手机", choice == Side.LOCAL) { onChoose(Side.LOCAL) }
            Choice("云端", choice == Side.REMOTE) { onChoose(Side.REMOTE) }
        }
        TextButton(onClick = { comparing = !comparing }) { Text(if (comparing) "收起" else "看看两边") }
        if (comparing) {
            Preview("这台手机", conflict.local)
            Preview("云端", conflict.cloud)
        }
    }
}

@Composable
private fun Note(text: String) {
    Text(text, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
}

@Composable
private fun Choice(label: String, selected: Boolean, onClick: () -> Unit) {
    Row(Modifier.clickable(onClick = onClick).padding(end = 12.dp), verticalAlignment = Alignment.CenterVertically) {
        RadioButton(selected = selected, onClick = onClick)
        Text(label, style = MaterialTheme.typography.bodyMedium)
    }
}

@Composable
private fun Preview(title: String, content: ByteArray?) {
    Column(Modifier.padding(top = 8.dp)) {
        Text(title, style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Surface(color = MaterialTheme.colorScheme.surfaceContainer, shape = MaterialTheme.shapes.small) {
            Text(
                previewText(content),
                style = MaterialTheme.typography.bodySmall,
                modifier = Modifier.fillMaxWidth().heightIn(max = 200.dp).verticalScroll(rememberScrollState()).padding(8.dp),
            )
        }
    }
}

private fun previewText(content: ByteArray?): String {
    if (content == null) return "（已删除）"
    // Strict decoding: a file that is not text (say an image) must not be shown as garbage.
    val text = runCatching {
        Charsets.UTF_8.newDecoder()
            .onMalformedInput(java.nio.charset.CodingErrorAction.REPORT)
            .decode(java.nio.ByteBuffer.wrap(content))
            .toString()
    }.getOrNull() ?: return "（不是文字，无法预览）"
    return text.ifEmpty { "（空白）" }
}

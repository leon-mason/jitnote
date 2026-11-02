package io.github.leonmason.jitnote.ui

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ListItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.github.leonmason.jitnote.data.Notebooks
import io.github.leonmason.jitnote.data.ViewMode

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(notebooks: Notebooks, nav: Navigator) {
    val state by notebooks.state.collectAsStateWithLifecycle()
    Scaffold(topBar = { BackTopBar("设置", onBack = nav::pop) }) { padding ->
        Column(Modifier.padding(padding)) {
            ListItem(
                headlineContent = { Text("显示隐藏文件") },
                supportingContent = {
                    Text("显示以 . 开头的文件和文件夹，比如 .obsidian、.gitignore。Git 自己的 .git 文件夹始终不显示。")
                },
                trailingContent = {
                    Switch(checked = state.showHiddenFiles, onCheckedChange = notebooks::setShowHiddenFiles)
                },
            )
            ListItem(
                headlineContent = { Text("打开笔记时默认为") },
                supportingContent = {
                    Column {
                        Text("新建的笔记和纯文本文件总是编辑。")
                        val modes = listOf(ViewMode.EDIT to "编辑", ViewMode.PREVIEW to "预览")
                        SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth().padding(top = 12.dp)) {
                            modes.forEachIndexed { index, (mode, label) ->
                                SegmentedButton(
                                    selected = state.defaultViewMode == mode,
                                    onClick = { notebooks.setDefaultViewMode(mode) },
                                    shape = SegmentedButtonDefaults.itemShape(index, modes.size),
                                ) { Text(label) }
                            }
                        }
                    }
                },
            )
        }
    }
}

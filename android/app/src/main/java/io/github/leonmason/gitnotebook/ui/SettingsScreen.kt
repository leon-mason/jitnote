package io.github.leonmason.gitnotebook.ui

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.ListItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.github.leonmason.gitnotebook.data.Notebooks

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
        }
    }
}

package io.github.leonmason.gitnotebook.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Tab
import androidx.compose.material3.TabRow
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.github.leonmason.gitnotebook.data.Account
import io.github.leonmason.gitnotebook.data.Notebooks
import io.github.leonmason.gitnotebook.data.RepoNames
import kotlinx.coroutines.launch

@Composable
fun NewNotebookScreen(notebooks: Notebooks, nav: Navigator) {
    val state by notebooks.state.collectAsStateWithLifecycle()
    val creatable = state.accounts.filter { it.provider.canCreateRepos }
    var tab by remember { mutableStateOf(if (creatable.isEmpty()) 1 else 0) }
    var busy by remember { mutableStateOf<String?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()

    fun run(action: suspend ((String) -> Unit) -> String) {
        error = null
        busy = "请稍候…"
        scope.launch {
            try {
                val id = action { busy = it }
                nav.replace(Screen.Folder(id))
            } catch (e: Exception) {
                error = e.message ?: "出错了，请重试"
            } finally {
                busy = null
            }
        }
    }

    Scaffold(topBar = { BackTopBar("添加笔记本", onBack = { if (busy == null) nav.pop() }) }) { padding ->
        Column(Modifier.fillMaxSize().padding(padding).imePadding()) {
            TabRow(selectedTabIndex = tab) {
                Tab(selected = tab == 0, onClick = { if (busy == null) tab = 0 }, text = { Text("新建") })
                Tab(selected = tab == 1, onClick = { if (busy == null) tab = 1 }, text = { Text("用已有的") })
            }
            // Forms stay composed under the progress overlay, so input survives an error.
            Box(Modifier.fillMaxSize()) {
                if (tab == 0) {
                    CreateForm(creatable, error) { name, account, path ->
                        run { progress -> notebooks.create(name, account, path, progress).id }
                    }
                } else {
                    ExistingNotebookForm(notebooks, state.accounts, error) { url, account, name ->
                        run { progress -> notebooks.import(url, account, name, progress).id }
                    }
                }
                val progress = busy
                if (progress != null) {
                    Surface(Modifier.fillMaxSize()) {
                        Column(
                            Modifier.padding(32.dp),
                            horizontalAlignment = Alignment.CenterHorizontally,
                            verticalArrangement = Arrangement.Center,
                        ) {
                            CircularProgressIndicator()
                            Spacer(Modifier.size(16.dp))
                            Text(progress, style = MaterialTheme.typography.bodyLarge)
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun CreateForm(accounts: List<Account>, error: String?, onCreate: (String, Account, String) -> Unit) {
    var name by remember { mutableStateOf("") }
    var account by remember { mutableStateOf(accounts.firstOrNull()) }
    var advanced by remember { mutableStateOf(false) }
    var customPath by remember { mutableStateOf<String?>(null) }
    val autoPath = remember(name) { RepoNames.fromName(name) }
    val path = customPath ?: autoPath

    if (accounts.isEmpty()) {
        EmptyState("这个账号不能新建", "「其他」类型的账号只能用已有的仓库，请切到「用已有的」。想新建的话，请先连接 Gitee 或 GitHub 账号。")
        return
    }
    Column(
        Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        OutlinedTextField(
            value = name,
            onValueChange = { name = it },
            label = { Text("笔记本名称") },
            placeholder = { Text("比如：读书笔记、工作日志") },
            singleLine = true,
            modifier = Modifier.fillMaxWidth(),
        )
        if (accounts.size > 1) {
            Text("保存到", style = MaterialTheme.typography.titleSmall)
            AccountPicker(accounts, account) { account = it }
        }
        Text(
            "会在你的 ${account?.provider?.label ?: ""} 账号里建一个只有你自己能看到的存储空间。",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        TextButton(onClick = { advanced = !advanced }) { Text(if (advanced) "收起高级选项" else "高级选项") }
        if (advanced) {
            OutlinedTextField(
                value = path,
                onValueChange = { customPath = it },
                label = { Text("云端仓库名（英文）") },
                supportingText = { Text("只能用英文字母、数字和 - _ .，以字母开头。一般不用改。") },
                isError = path.isNotEmpty() && !RepoNames.isValid(path),
                singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Ascii),
                modifier = Modifier.fillMaxWidth(),
            )
        }
        error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
        Button(
            enabled = name.isNotBlank() && account != null && RepoNames.isValid(path),
            onClick = { onCreate(name.trim(), account!!, path) },
            modifier = Modifier.fillMaxWidth(),
        ) { Text("创建") }
    }
}

@Composable
internal fun AccountPicker(accounts: List<Account>, selected: Account?, onSelect: (Account) -> Unit) {
    Column {
        accounts.forEach { account ->
            Row(
                Modifier.fillMaxWidth().clickable { onSelect(account) }.padding(vertical = 4.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                RadioButton(selected = account.id == selected?.id, onClick = { onSelect(account) })
                Text("${account.provider.label} · ${account.login}")
            }
        }
    }
}

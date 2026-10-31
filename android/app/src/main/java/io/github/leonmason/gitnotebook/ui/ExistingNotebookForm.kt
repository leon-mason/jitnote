package io.github.leonmason.gitnotebook.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Book
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.FolderOpen
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import io.github.leonmason.gitnotebook.data.Account
import io.github.leonmason.gitnotebook.data.HostingApi.RemoteRepo
import io.github.leonmason.gitnotebook.data.Notebooks
import io.github.leonmason.gitnotebook.data.RepoUrls

/**
 * Turns something already in the user's account into a notebook. Everything in the account is
 * listed (not only what this app created), because people often already keep notes there.
 */
@Composable
fun ExistingNotebookForm(
    notebooks: Notebooks,
    accounts: List<Account>,
    error: String?,
    onImport: (url: String, account: Account, name: String) -> Unit,
) {
    var account by remember { mutableStateOf(accounts.firstOrNull()) }
    val selected = account
    var byUrl by remember(selected) { mutableStateOf(selected?.provider?.canCreateRepos == false) }
    var picking by remember { mutableStateOf<RemoteRepo?>(null) }

    Column(Modifier.fillMaxSize()) {
        if (accounts.size > 1) {
            Column(Modifier.padding(horizontal = 16.dp, vertical = 8.dp)) {
                AccountPicker(accounts, selected) { account = it }
            }
        }
        error?.let { Text(it, color = MaterialTheme.colorScheme.error, modifier = Modifier.padding(16.dp)) }
        when {
            selected == null -> Unit
            byUrl -> UrlForm(selected, canGoBack = selected.provider.canCreateRepos, onBack = { byUrl = false }, onImport = onImport)
            else -> RepoList(notebooks, selected, onPick = { picking = it }, onUseUrl = { byUrl = true })
        }
    }

    val repo = picking
    if (repo != null && selected != null) {
        ConfirmImportDialog(repo, onDismiss = { picking = null }) { name ->
            picking = null
            onImport(repo.cloneUrl, selected, name)
        }
    }
}

@Composable
private fun RepoList(notebooks: Notebooks, account: Account, onPick: (RemoteRepo) -> Unit, onUseUrl: () -> Unit) {
    var repos by remember(account) { mutableStateOf<List<Pair<RemoteRepo, Boolean>>?>(null) }
    var loadError by remember(account) { mutableStateOf<String?>(null) }
    var retry by remember { mutableIntStateOf(0) }
    var query by remember { mutableStateOf("") }

    LaunchedEffect(account, retry) {
        loadError = null
        try {
            repos = notebooks.listRemote(account)
        } catch (e: Exception) {
            loadError = e.message ?: "读取失败"
        }
    }

    val list = repos
    when {
        loadError != null -> Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text("没能读取账号里的内容：$loadError", color = MaterialTheme.colorScheme.error)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Button(onClick = { retry++ }) { Text("重试") }
                OutlinedButton(onClick = onUseUrl) { Text("手动填写网址") }
            }
        }
        list == null -> Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
            CircularProgressIndicator(strokeWidth = 2.dp, modifier = Modifier.size(20.dp))
            Spacer(Modifier.size(12.dp))
            Text("正在读取你 ${account.provider.label} 账号里的内容…")
        }
        else -> {
            val keyword = query.trim()
            val shown = if (keyword.isEmpty()) list else list.filter { (repo, _) ->
                repo.displayName.contains(keyword, ignoreCase = true) || repo.path.contains(keyword, ignoreCase = true)
            }
            val ours = shown.filter { it.first.isNotebook }
            val others = shown.filterNot { it.first.isNotebook }
            LazyColumn(Modifier.fillMaxSize()) {
                item {
                    Text(
                        "选一个你 ${account.provider.label} 账号里已有的仓库，它会直接变成笔记本。" +
                            "里面原有的文件都会原样保留，在手机上写的笔记也会同步回去。",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(16.dp),
                    )
                }
                if (list.size > 6) {
                    item {
                        OutlinedTextField(
                            value = query,
                            onValueChange = { query = it },
                            placeholder = { Text("搜索名字") },
                            leadingIcon = { Icon(Icons.Outlined.Search, contentDescription = null) },
                            singleLine = true,
                            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
                        )
                    }
                }
                if (list.isEmpty()) {
                    item { EmptyState("账号里还是空的", "没有找到任何仓库。可以回到「新建」建一个新的笔记本。") }
                } else if (shown.isEmpty()) {
                    item { EmptyState("没有找到", "换个名字搜搜看。") }
                }
                if (ours.isNotEmpty()) {
                    item { SectionTitle("以前用这个 App 建的笔记本") }
                    items(ours, key = { it.first.cloneUrl }) { (repo, added) -> RepoRow(repo, added, account) { onPick(repo) } }
                }
                if (others.isNotEmpty()) {
                    item { SectionTitle(if (ours.isEmpty()) "账号里的仓库" else "账号里的其他仓库") }
                    items(others, key = { it.first.cloneUrl }) { (repo, added) -> RepoRow(repo, added, account) { onPick(repo) } }
                }
                item {
                    TextButton(onClick = onUseUrl, modifier = Modifier.padding(8.dp)) { Text("列表里没有？手动填写网址") }
                }
            }
        }
    }
}

@Composable
private fun SectionTitle(text: String) {
    Text(
        text,
        style = MaterialTheme.typography.titleSmall,
        color = MaterialTheme.colorScheme.primary,
        modifier = Modifier.padding(start = 16.dp, end = 16.dp, top = 16.dp, bottom = 4.dp),
    )
}

@Composable
private fun RepoRow(repo: RemoteRepo, added: Boolean, account: Account, onClick: () -> Unit) {
    val details = buildList {
        add(if (repo.isPrivate) "仅自己可见" else "所有人可见")
        repo.updatedAt?.let { add(relativeDays(it) + "更新") }
        if (!repo.owner.equals(account.login, ignoreCase = true)) add("属于 ${repo.owner}")
    }.joinToString(" · ")
    ListItem(
        leadingContent = {
            Icon(if (repo.isNotebook) Icons.Outlined.Book else Icons.Outlined.FolderOpen, contentDescription = null)
        },
        headlineContent = { Text(repo.displayName) },
        supportingContent = { Text(details) },
        trailingContent = if (added) {
            {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Outlined.CheckCircle, contentDescription = null, modifier = Modifier.size(16.dp))
                    Spacer(Modifier.size(4.dp))
                    Text("已在手机上", style = MaterialTheme.typography.labelMedium)
                }
            }
        } else {
            null
        },
        modifier = if (added) Modifier else Modifier.clickable(onClick = onClick),
    )
}

@Composable
private fun ConfirmImportDialog(repo: RemoteRepo, onDismiss: () -> Unit, onConfirm: (String) -> Unit) {
    var name by remember { mutableStateOf(repo.displayName) }
    val sizeMb = repo.sizeKb?.let { it / 1024 }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("把它变成笔记本") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                OutlinedTextField(
                    value = name,
                    onValueChange = { name = it },
                    label = { Text("在 App 里叫什么") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
                Text(
                    "里面原有的文件和文件夹都会原样保留。在手机上新写或修改的笔记，点同步后会保存回这个仓库。",
                    style = MaterialTheme.typography.bodyMedium,
                )
                if (!repo.isPrivate) {
                    Text(
                        "注意：这个仓库是公开的，所有人都能看到里面的笔记。",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.error,
                    )
                }
                if (sizeMb != null && sizeMb >= 50) {
                    Text(
                        "这个仓库比较大（约 $sizeMb MB），第一次下载会花一些时间，建议连着 Wi-Fi。",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        },
        confirmButton = {
            TextButton(onClick = { onConfirm(name.trim()) }, enabled = name.isNotBlank()) { Text("开始下载") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("取消") } },
    )
}

@Composable
private fun UrlForm(account: Account, canGoBack: Boolean, onBack: () -> Unit, onImport: (String, Account, String) -> Unit) {
    var url by remember { mutableStateOf("") }
    var name by remember { mutableStateOf("") }
    Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        Text(
            "在电脑上打开仓库页面，复制浏览器地址栏里的网址，粘贴到这里。",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        OutlinedTextField(
            value = url,
            onValueChange = { url = it },
            label = { Text("网址") },
            placeholder = { Text("https://gitee.com/用户名/仓库") },
            singleLine = true,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
            modifier = Modifier.fillMaxWidth(),
        )
        OutlinedTextField(
            value = name,
            onValueChange = { name = it },
            label = { Text("在 App 里叫什么（可不填）") },
            singleLine = true,
            modifier = Modifier.fillMaxWidth(),
        )
        Button(
            enabled = url.trim().startsWith("http"),
            onClick = { onImport(RepoUrls.toCloneUrl(url), account, name.trim()) },
            modifier = Modifier.fillMaxWidth(),
        ) { Text("开始下载") }
        if (canGoBack) {
            OutlinedButton(onClick = onBack, modifier = Modifier.fillMaxWidth()) { Text("从账号里选") }
        }
    }
}

/** "今天", "昨天", "3 天前", "2 个月前", "1 年前". */
fun relativeDays(millis: Long, now: Long = System.currentTimeMillis()): String {
    val days = ((now - millis) / 86_400_000L).coerceAtLeast(0)
    return when {
        days == 0L -> "今天"
        days == 1L -> "昨天"
        days < 30 -> "$days 天前"
        days < 365 -> "${days / 30} 个月前"
        else -> "${days / 365} 年前"
    }
}

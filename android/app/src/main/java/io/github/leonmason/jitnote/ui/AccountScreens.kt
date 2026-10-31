package io.github.leonmason.jitnote.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.Visibility
import androidx.compose.material.icons.outlined.VisibilityOff
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExtendedFloatingActionButton
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
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
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.github.leonmason.jitnote.data.Account
import io.github.leonmason.jitnote.data.Notebooks
import io.github.leonmason.jitnote.data.Provider
import kotlinx.coroutines.launch

@Composable
fun AccountsScreen(notebooks: Notebooks, nav: Navigator) {
    val state by notebooks.state.collectAsStateWithLifecycle()
    var removing by remember { mutableStateOf<Account?>(null) }
    var blocked by remember { mutableStateOf<Account?>(null) }

    Scaffold(
        topBar = { BackTopBar("云端账号", onBack = nav::pop) },
        floatingActionButton = {
            ExtendedFloatingActionButton(
                onClick = { nav.push(Screen.AddAccount) },
                icon = { Icon(Icons.Default.Add, contentDescription = null) },
                text = { Text("连接账号") },
            )
        },
    ) { padding ->
        if (state.accounts.isEmpty()) {
            EmptyState("还没有连接账号", "连接 Gitee 或 GitHub 账号后，笔记会保存到你自己的账号里。", Modifier.padding(padding))
        } else {
            LazyColumn(contentPadding = padding) {
                items(state.accounts, key = { it.id }) { account ->
                    val used = state.notebooks.count { it.accountId == account.id }
                    ListItem(
                        headlineContent = { Text("${account.provider.label} · ${account.login}") },
                        supportingContent = { Text(if (used > 0) "$used 个笔记本在用" else "没有笔记本在用") },
                        trailingContent = {
                            IconButton(onClick = { if (used > 0) blocked = account else removing = account }) {
                                Icon(Icons.Outlined.Delete, contentDescription = "断开")
                            }
                        },
                    )
                }
            }
        }
    }

    removing?.let { account ->
        ConfirmDialog(
            title = "断开 ${account.login}？",
            text = "这台手机会删除保存的授权，云端账号和笔记不受影响。",
            confirmLabel = "断开",
            destructive = true,
            onDismiss = { removing = null },
        ) {
            notebooks.removeAccount(account)
            removing = null
        }
    }
    blocked?.let {
        ConfirmDialog(
            title = "还有笔记本在用这个账号",
            text = "请先在首页把用到它的笔记本从这台手机移除，再断开账号。\n如果只是授权过期了，直接点「连接账号」重新连接同一个账号即可。",
            confirmLabel = "知道了",
            onDismiss = { blocked = null },
            onConfirm = { blocked = null },
        )
    }
}

@Composable
fun AddAccountScreen(notebooks: Notebooks, nav: Navigator) {
    var provider by remember { mutableStateOf(Provider.GITEE) }
    var token by remember { mutableStateOf("") }
    var username by remember { mutableStateOf("") }
    var email by remember { mutableStateOf("") }
    var showToken by remember { mutableStateOf(false) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    val uri = LocalUriHandler.current

    val canSubmit = token.isNotBlank() && (provider != Provider.OTHER || username.isNotBlank()) && !busy

    Scaffold(topBar = { BackTopBar("连接云端账号", onBack = nav::pop) }) { padding ->
        Column(
            Modifier
                .fillMaxSize()
                .padding(padding)
                .imePadding()
                .verticalScroll(rememberScrollState())
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Text("笔记保存在哪里？", style = MaterialTheme.typography.titleSmall)
            SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
                val options = listOf(Provider.GITEE, Provider.GITHUB, Provider.OTHER)
                options.forEachIndexed { index, option ->
                    SegmentedButton(
                        selected = provider == option,
                        onClick = {
                            provider = option
                            error = null
                        },
                        shape = SegmentedButtonDefaults.itemShape(index, options.size),
                    ) { Text(if (option == Provider.OTHER) "其他" else option.label) }
                }
            }

            Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainer)) {
                Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    when (provider) {
                        Provider.GITEE -> {
                            Text("Gitee（码云）国内访问快，推荐。", fontWeight = FontWeight.Medium)
                            Step(1, "还没有 Gitee 账号的话，先在 gitee.com 免费注册一个。")
                            Step(2, "点下面的按钮，登录后会打开「生成私人令牌」页面。")
                            Step(3, "描述随便填（比如“笔记”），权限保持默认勾选，点「提交」。")
                            Step(4, "复制页面上显示的一长串字符，粘贴到下面。")
                            FilledTonalButton(onClick = { uri.openUri("https://gitee.com/profile/personal_access_tokens/new") }) {
                                Text("打开 Gitee 生成页面")
                            }
                        }
                        Provider.GITHUB -> {
                            Text("GitHub 在国内有时连接不稳定。", fontWeight = FontWeight.Medium)
                            Step(1, "点下面的按钮，登录 GitHub 后会打开生成令牌的页面（已帮你勾好需要的权限）。")
                            Step(2, "Expiration（有效期）建议选 No expiration（不过期），拉到页面底部点 Generate token。")
                            Step(3, "复制以 ghp_ 开头的那串字符，粘贴到下面。")
                            FilledTonalButton(onClick = {
                                uri.openUri("https://github.com/settings/tokens/new?scopes=repo&description=Jitnote")
                            }) { Text("打开 GitHub 生成页面") }
                        }
                        Provider.OTHER -> {
                            Text("适合自己搭建的 Gitea、GitLab 等服务。", fontWeight = FontWeight.Medium)
                            Text(
                                "填写登录用户名，以及密码或访问令牌。这种方式只能下载已经存在的笔记本，不能在这里新建。",
                                style = MaterialTheme.typography.bodyMedium,
                            )
                        }
                    }
                }
            }

            if (provider == Provider.OTHER) {
                OutlinedTextField(
                    value = username,
                    onValueChange = { username = it },
                    label = { Text("用户名") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
                OutlinedTextField(
                    value = email,
                    onValueChange = { email = it },
                    label = { Text("邮箱（可不填）") },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Email),
                    modifier = Modifier.fillMaxWidth(),
                )
            }
            OutlinedTextField(
                value = token,
                onValueChange = {
                    token = it
                    error = null
                },
                label = { Text(if (provider == Provider.OTHER) "密码或访问令牌" else "粘贴令牌") },
                singleLine = true,
                visualTransformation = if (showToken) VisualTransformation.None else PasswordVisualTransformation(),
                trailingIcon = {
                    IconButton(onClick = { showToken = !showToken }) {
                        Icon(
                            if (showToken) Icons.Outlined.VisibilityOff else Icons.Outlined.Visibility,
                            contentDescription = if (showToken) "隐藏" else "显示",
                        )
                    }
                },
                isError = error != null,
                supportingText = {
                    Text(error ?: "令牌只加密保存在这台手机上，不会发给任何第三方。")
                },
                modifier = Modifier.fillMaxWidth(),
            )
            Button(
                enabled = canSubmit,
                modifier = Modifier.fillMaxWidth(),
                onClick = {
                    busy = true
                    error = null
                    scope.launch {
                        try {
                            notebooks.addAccount(provider, token, username, email)
                            nav.pop()
                            // First account and nothing yet: go straight on to adding a notebook.
                            if (notebooks.state.value.notebooks.isEmpty()) nav.push(Screen.NewNotebook)
                        } catch (e: Exception) {
                            error = "连接失败：${e.message ?: "请检查令牌是否复制完整"}"
                        } finally {
                            busy = false
                        }
                    }
                },
            ) {
                if (busy) {
                    CircularProgressIndicator(strokeWidth = 2.dp, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.size(8.dp))
                    Text("正在验证…")
                } else {
                    Text("连接")
                }
            }
            TextButton(onClick = nav::pop, modifier = Modifier.align(Alignment.CenterHorizontally)) { Text("以后再说") }
        }
    }
}

@Composable
private fun Step(number: Int, text: String) {
    Row(verticalAlignment = Alignment.Top) {
        Text("$number.", fontWeight = FontWeight.SemiBold, modifier = Modifier.padding(end = 8.dp))
        Text(text, style = MaterialTheme.typography.bodyMedium)
    }
}


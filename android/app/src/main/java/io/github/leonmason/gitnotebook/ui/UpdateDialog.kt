package io.github.leonmason.gitnotebook.ui

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.core.content.FileProvider
import androidx.lifecycle.compose.LifecycleResumeEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.github.leonmason.gitnotebook.data.AppUpdates
import io.github.leonmason.gitnotebook.data.AppUpdates.State
import java.io.File
import java.util.Locale

/** Shows the update flow over whichever screen is open: new version → download → system installer. */
@Composable
fun UpdateDialog(updates: AppUpdates) {
    val state by updates.state.collectAsStateWithLifecycle()
    when (val s = state) {
        State.Idle -> Unit
        State.Checking -> AlertDialog(
            onDismissRequest = updates::dismiss,
            text = {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                    CircularProgressIndicator(strokeWidth = 2.dp, modifier = Modifier.size(22.dp))
                    Text("正在检查更新…")
                }
            },
            confirmButton = { TextButton(onClick = updates::dismiss) { Text("取消") } },
        )
        State.UpToDate -> AlertDialog(
            onDismissRequest = updates::dismiss,
            title = { Text("已经是最新版本") },
            text = { Text("当前版本 ${updates.currentVersion}") },
            confirmButton = { TextButton(onClick = updates::dismiss) { Text("好") } },
        )
        is State.Available -> AlertDialog(
            onDismissRequest = updates::dismiss,
            title = { Text("有新版本 ${s.release.version}") },
            text = {
                Column(Modifier.heightIn(max = 280.dp).verticalScroll(rememberScrollState())) {
                    if (s.release.notes.isNotEmpty()) Text(s.release.notes)
                    if (s.release.apkSize > 0) {
                        Text(
                            "安装包 ${megabytes(s.release.apkSize)}",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
            },
            confirmButton = { TextButton(onClick = { updates.download(s.release) }) { Text("更新") } },
            dismissButton = { TextButton(onClick = updates::dismiss) { Text("以后再说") } },
        )
        is State.Downloading -> AlertDialog(
            // Only the button cancels, so a stray tap outside doesn't throw away the download.
            onDismissRequest = {},
            title = { Text("正在下载新版本…") },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    if (s.release.apkSize > 0) {
                        LinearProgressIndicator(
                            progress = { (s.downloaded.toFloat() / s.release.apkSize).coerceIn(0f, 1f) },
                            modifier = Modifier.fillMaxWidth(),
                        )
                        Text("${megabytes(s.downloaded)} / ${megabytes(s.release.apkSize)}")
                    } else {
                        LinearProgressIndicator(Modifier.fillMaxWidth())
                        Text(megabytes(s.downloaded))
                    }
                }
            },
            confirmButton = { TextButton(onClick = updates::dismiss) { Text("取消") } },
        )
        is State.Downloaded -> InstallDialog(s, onDismiss = updates::dismiss)
        is State.Failed -> AlertDialog(
            onDismissRequest = updates::dismiss,
            title = { Text(if (s.release == null) "检查更新没有成功" else "更新没有成功") },
            text = { Text(s.message) },
            confirmButton = {
                if (s.release != null) {
                    TextButton(onClick = { updates.download(s.release) }) { Text("重试") }
                } else {
                    TextButton(onClick = updates::checkNow) { Text("重试") }
                }
            },
            dismissButton = { TextButton(onClick = updates::dismiss) { Text("取消") } },
        )
    }
}

/**
 * Opens the system installer as soon as the download is done. Stays up underneath it, so a user who
 * cancels the installer can try again, and walks them through allowing installs the first time.
 */
@Composable
private fun InstallDialog(state: State.Downloaded, onDismiss: () -> Unit) {
    val context = LocalContext.current
    var allowed by remember { mutableStateOf(context.canInstallPackages()) }
    var launched by remember(state.apk) { mutableStateOf(false) }

    // Coming back from the "install unknown apps" setting.
    LifecycleResumeEffect(Unit) {
        allowed = context.canInstallPackages()
        onPauseOrDispose {}
    }
    LaunchedEffect(allowed, state.apk) {
        if (allowed && !launched) {
            launched = true
            context.installApk(state.apk)
        }
    }

    if (allowed) {
        AlertDialog(
            onDismissRequest = onDismiss,
            title = { Text("新版本 ${state.release.version} 已下载好") },
            text = { Text("在系统弹出的窗口里点「更新」就装好了。") },
            confirmButton = { TextButton(onClick = { context.installApk(state.apk) }) { Text("安装") } },
            dismissButton = { TextButton(onClick = onDismiss) { Text("以后再说") } },
        )
    } else {
        AlertDialog(
            onDismissRequest = onDismiss,
            title = { Text("还差一步") },
            text = {
                Text(
                    "新版本已经下载好。安卓系统要求先允许「Git 笔记本」安装应用，才能更新自己。\n\n" +
                        "点「去允许」，打开开关后返回这里就会开始安装。每台手机只需要允许一次。",
                )
            },
            confirmButton = { TextButton(onClick = { context.openInstallPermissionSettings() }) { Text("去允许") } },
            dismissButton = { TextButton(onClick = onDismiss) { Text("取消") } },
        )
    }
}

private fun Context.canInstallPackages() = packageManager.canRequestPackageInstalls()

private fun Context.openInstallPermissionSettings() {
    startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName")))
}

private fun Context.installApk(apk: File) {
    val uri = FileProvider.getUriForFile(this, "$packageName.updates", apk)
    startActivity(
        Intent(Intent.ACTION_VIEW)
            .setDataAndType(uri, "application/vnd.android.package-archive")
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION),
    )
}

private fun megabytes(bytes: Long) = String.format(Locale.ROOT, "%.1f MB", bytes / 1024.0 / 1024.0)

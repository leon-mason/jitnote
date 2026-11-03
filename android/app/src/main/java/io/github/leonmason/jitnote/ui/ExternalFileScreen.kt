package io.github.leonmason.jitnote.ui

import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.webkit.MimeTypeMap
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.core.content.FileProvider
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import io.github.leonmason.jitnote.data.ExternalFiles
import io.github.leonmason.jitnote.data.Notebooks
import java.io.File

/** A file this app cannot show. The button hands the notebook file to the phone's default app. */
@Composable
fun ExternalFileScreen(notebooks: Notebooks, nav: Navigator, screen: Screen.ExternalFile) {
    val notebook = notebooks.notebook(screen.notebookId) ?: return
    val root = notebooks.dir(notebook)
    val file = File(root, screen.path)
    val context = LocalContext.current
    var error by remember { mutableStateOf<String?>(null) }
    var handedOff by remember { mutableStateOf(false) }
    val missing = !file.isFile || !ExternalFiles.isInside(root, file)

    // The other app writes the file while this one is stopped. Coming back is "done editing".
    LifecycleEventEffect(Lifecycle.Event.ON_RESUME) {
        if (handedOff) notebooks.commitInBackground(notebook)
    }

    Scaffold(topBar = { BackTopBar(file.name, onBack = nav::pop) }) { padding ->
        if (missing) {
            EmptyState("这个文件不在了", "可能已经删除或移动。", Modifier.padding(padding))
        } else {
            EmptyState(
                title = "记特不能直接打开",
                body = "保存后改的就是仓库里的这个文件。回到这里会留下一个版本，同步后其他设备也能拿到。",
                modifier = Modifier.padding(padding),
            ) {
                Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Button(onClick = {
                        error = context.openWithDefaultApp(root, file)
                        if (error == null) handedOff = true
                    }) {
                        Text("使用手机默认程序打开")
                    }
                    error?.let {
                        Text(
                            it,
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.error,
                            textAlign = TextAlign.Center,
                        )
                    }
                }
            }
        }
    }
}

/**
 * Opens [file] in the phone's default app. Returns a message when that cannot happen.
 * The link allows that app to overwrite this one notebook file and nothing else.
 */
private fun Context.openWithDefaultApp(root: File, file: File): String? {
    if (!file.isFile || !ExternalFiles.isInside(root, file)) return "这个文件不在了"
    val mime = ExternalFiles.mimeType(file.name) { ext ->
        MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext)
    }
    val uri = try {
        FileProvider.getUriForFile(this, "$packageName.files", file)
    } catch (_: IllegalArgumentException) {
        return "这个文件打不开"
    }
    val grant = Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
    for (action in ExternalFiles.actions()) {
        // clipData carries the same link: some apps only receive the grant from one of the two.
        val intent = Intent(action).apply {
            setDataAndType(uri, mime)
            addFlags(grant)
            clipData = ClipData.newRawUri(file.name, uri)
        }
        try {
            startActivity(intent)
            return null
        } catch (_: ActivityNotFoundException) {
            continue
        }
    }
    return "手机上没有能打开这种文件的程序"
}

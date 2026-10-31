package io.github.leonmason.gitnotebook.ui

import android.annotation.SuppressLint
import android.content.Intent
import android.net.Uri
import android.util.Log
import android.webkit.ConsoleMessage
import android.webkit.JavascriptInterface
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.viewinterop.AndroidView
import androidx.webkit.WebViewAssetLoader
import androidx.webkit.WebViewClientCompat
import io.github.leonmason.gitnotebook.data.NoteAssets
import org.json.JSONObject
import org.json.JSONTokener
import java.io.File

private const val HOST = "appassets.androidplatform.net"
private const val EDITOR_URL = "https://$HOST/assets/editor/index.html"

/**
 * Lets the screen read the editor's Markdown. When the WebView leaves the screen, its final
 * content is passed to [onClose] (e.g. to save it) before the WebView is destroyed.
 */
class EditorHandle(private val onClose: ((String?) -> Unit)? = null) {
    internal var webView: WebView? = null

    /** Calls [onResult] with the editor's current Markdown, or null if it is not available. */
    fun read(onResult: (String?) -> Unit) {
        val view = webView ?: return onResult(null)
        view.evaluateJavascript(GET_MARKDOWN) { onResult(decode(it)) }
    }

    internal fun release(view: WebView) {
        if (webView === view) webView = null
        val callback = onClose ?: return view.destroy()
        view.evaluateJavascript(GET_MARKDOWN) { raw ->
            callback(decode(raw))
            view.destroy()
        }
    }

    private fun decode(raw: String?) = runCatching { JSONTokener(raw).nextValue() as? String }.getOrNull()

    private companion object {
        const val GET_MARKDOWN = "window.GitNotebookEditor ? window.GitNotebookEditor.getMarkdown() : null"
    }
}

/**
 * The shared web editor (see /editor in the repository) showing one note.
 * Images are found like other editors do (see [NoteAssets]) and served from the notebook folder.
 * [onChange] is called on a background thread.
 */
@SuppressLint("SetJavaScriptEnabled")
@Composable
fun NoteWebView(
    notebookRoot: File,
    notePath: String,
    content: String,
    readonly: Boolean,
    handle: EditorHandle,
    modifier: Modifier = Modifier,
    onChange: (String) -> Unit = {},
    onOpenImage: (notebookPath: String) -> Unit = {},
) {
    val latestOnChange by rememberUpdatedState(onChange)
    val latestOnOpenImage by rememberUpdatedState(onOpenImage)
    val assets = remember(notebookRoot) { NoteAssets(notebookRoot) }
    val background = MaterialTheme.colorScheme.background.toArgb()
    val folder = notePath.substringBeforeLast('/', "")
    val notebookUrl = "https://$HOST/notebook/"
    val baseUrl = notebookUrl + folder.split('/').filter { it.isNotEmpty() }.joinToString("") { Uri.encode(it) + "/" }

    AndroidView(
        modifier = modifier,
        factory = { context ->
            val loader = WebViewAssetLoader.Builder()
                .addPathHandler("/assets/", WebViewAssetLoader.AssetsPathHandler(context))
                .addPathHandler("/notebook/", WebViewAssetLoader.InternalStoragePathHandler(context, notebookRoot))
                .build()
            WebView(context).apply {
                setBackgroundColor(background)
                settings.javaScriptEnabled = true
                settings.domStorageEnabled = true
                settings.allowFileAccess = false
                settings.allowContentAccess = false
                webChromeClient = object : WebChromeClient() {
                    override fun onConsoleMessage(message: ConsoleMessage): Boolean {
                        Log.d("GitNotebookEditor", "${message.message()} (${message.sourceId()}:${message.lineNumber()})")
                        return true
                    }
                }
                webViewClient = object : WebViewClientCompat() {
                    override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse? =
                        loader.shouldInterceptRequest(request.url)

                    override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
                        // Links inside notes open in the browser, never inside the editor.
                        runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, request.url)) }
                        return true
                    }
                }
                addJavascriptInterface(
                    object {
                        @JavascriptInterface
                        fun onReady() {
                            val options = JSONObject()
                                .put("readonly", readonly)
                                .put("baseUrl", baseUrl)
                                .put("notebookUrl", notebookUrl)
                            post {
                                evaluateJavascript(
                                    "window.GitNotebookEditor.load(${JSONObject.quote(content)}, $options)",
                                    null,
                                )
                            }
                        }

                        @JavascriptInterface
                        fun onChange(markdown: String) = latestOnChange(markdown)

                        @JavascriptInterface
                        fun resolveFile(path: String): String = assets.resolve(folder, path).orEmpty()

                        @JavascriptInterface
                        fun openImage(path: String) {
                            // Only open what resolveFile handed out, i.e. a file inside this notebook.
                            if (assets.resolve("", path) == path) post { latestOnOpenImage(path) }
                        }
                    },
                    "GitNotebookHost",
                )
                loadUrl(EDITOR_URL)
                handle.webView = this
            }
        },
        onRelease = { handle.release(it) },
    )
}

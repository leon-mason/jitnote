package io.github.leonmason.jitnote.ui

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Scaffold
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import io.github.leonmason.jitnote.data.Notebooks
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File

/** Shows one picture from a notebook full screen. Pinch or double-tap to zoom, drag to move. */
@Composable
fun ImageViewerScreen(notebooks: Notebooks, nav: Navigator, screen: Screen.Image) {
    val notebook = notebooks.notebook(screen.notebookId) ?: return
    val file = File(notebooks.dir(notebook), screen.path)
    val image by produceState<Result<ImageBitmap>?>(null, file) {
        value = withContext(Dispatchers.IO) { runCatching { decode(file) } }
    }
    var scale by remember { mutableFloatStateOf(1f) }
    var offset by remember { mutableStateOf(Offset.Zero) }

    Scaffold(topBar = { BackTopBar(file.name, onBack = nav::pop) }) { padding ->
        Box(
            Modifier
                .fillMaxSize()
                .padding(padding)
                .clipToBounds()
                .background(Color.Black)
                .pointerInput(Unit) {
                    detectTapGestures(onDoubleTap = { tap ->
                        if (scale > 1f) {
                            scale = 1f
                            offset = Offset.Zero
                        } else {
                            scale = 2.5f
                            // Zoom towards the tapped point.
                            offset = (Offset(size.width / 2f, size.height / 2f) - tap) * 1.5f
                        }
                    })
                }
                .pointerInput(Unit) {
                    detectTransformGestures { _, pan, zoom, _ ->
                        scale = (scale * zoom).coerceIn(1f, 8f)
                        offset = if (scale == 1f) Offset.Zero else offset + pan
                    }
                },
        ) {
            val result = image
            when {
                result == null -> Waiting("正在打开图片…")
                result.isFailure -> EmptyState("这张图片打不开", "可能是这台手机不支持的图片格式。")
                else -> Image(
                    bitmap = result.getOrThrow(),
                    contentDescription = file.name,
                    contentScale = ContentScale.Fit,
                    modifier = Modifier
                        .fillMaxSize()
                        .graphicsLayer {
                            scaleX = scale
                            scaleY = scale
                            translationX = offset.x
                            translationY = offset.y
                        },
                )
            }
        }
    }
}

/** Decodes [file], scaled down so neither side exceeds [maxSide] pixels (phone photos can be huge). */
fun decode(file: File, maxSide: Int = 4096): ImageBitmap {
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    BitmapFactory.decodeFile(file.path, bounds)
    require(bounds.outWidth > 0 && bounds.outHeight > 0) { "Unsupported image" }
    var sample = 1
    while (maxOf(bounds.outWidth, bounds.outHeight) / sample > maxSide) sample *= 2
    val bitmap: Bitmap = BitmapFactory.decodeFile(file.path, BitmapFactory.Options().apply { inSampleSize = sample })
        ?: error("Unsupported image")
    return bitmap.asImageBitmap()
}

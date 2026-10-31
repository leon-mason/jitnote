package io.github.leonmason.jitnote

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import io.github.leonmason.jitnote.ui.JitnoteTheme
import io.github.leonmason.jitnote.ui.JitnoteUi

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        val app = application as JitnoteApp
        setContent {
            JitnoteTheme {
                JitnoteUi(app.notebooks, app.updates)
            }
        }
    }
}

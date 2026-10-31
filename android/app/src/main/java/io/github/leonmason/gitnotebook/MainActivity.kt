package io.github.leonmason.gitnotebook

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import io.github.leonmason.gitnotebook.ui.GitNotebookTheme
import io.github.leonmason.gitnotebook.ui.GitNotebookUi

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        val notebooks = (application as GitNotebookApp).notebooks
        setContent {
            GitNotebookTheme {
                GitNotebookUi(notebooks)
            }
        }
    }
}

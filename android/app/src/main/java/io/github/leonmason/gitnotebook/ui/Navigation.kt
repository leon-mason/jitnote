package io.github.leonmason.gitnotebook.ui

import androidx.activity.compose.BackHandler
import androidx.compose.runtime.Composable
import androidx.compose.runtime.mutableStateListOf
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewmodel.compose.viewModel
import io.github.leonmason.gitnotebook.core.Version
import io.github.leonmason.gitnotebook.data.Notebooks

sealed interface Screen {
    data object Home : Screen
    data object Accounts : Screen
    data object AddAccount : Screen
    data object NewNotebook : Screen
    data class Folder(val notebookId: String, val path: String = "") : Screen
    data class Editor(val notebookId: String, val path: String) : Screen
    data class History(val notebookId: String, val path: String) : Screen
    data class VersionPreview(val notebookId: String, val path: String, val version: Version) : Screen
    data class Conflicts(val notebookId: String) : Screen
}

/** A plain back stack; survives rotation as a ViewModel. */
class Navigator : ViewModel() {
    val stack = mutableStateListOf<Screen>(Screen.Home)

    fun push(screen: Screen) {
        stack.add(screen)
    }

    fun pop() {
        if (stack.size > 1) stack.removeAt(stack.lastIndex)
    }

    fun replace(screen: Screen) {
        stack[stack.lastIndex] = screen
    }

    /** Pops until [predicate] matches the top screen (or only Home is left). */
    fun popUntil(predicate: (Screen) -> Boolean) {
        while (stack.size > 1 && !predicate(stack.last())) stack.removeAt(stack.lastIndex)
    }
}

@Composable
fun GitNotebookUi(notebooks: Notebooks, nav: Navigator = viewModel()) {
    BackHandler(enabled = nav.stack.size > 1) { nav.pop() }
    when (val screen = nav.stack.last()) {
        Screen.Home -> HomeScreen(notebooks, nav)
        Screen.Accounts -> AccountsScreen(notebooks, nav)
        Screen.AddAccount -> AddAccountScreen(notebooks, nav)
        Screen.NewNotebook -> NewNotebookScreen(notebooks, nav)
        is Screen.Folder -> FolderScreen(notebooks, nav, screen)
        is Screen.Editor -> EditorScreen(notebooks, nav, screen)
        is Screen.History -> HistoryScreen(notebooks, nav, screen)
        is Screen.VersionPreview -> VersionPreviewScreen(notebooks, nav, screen)
        is Screen.Conflicts -> ConflictsScreen(notebooks, nav, screen)
    }
}

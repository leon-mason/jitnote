package io.github.leonmason.jitnote.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewmodel.compose.viewModel
import io.github.leonmason.jitnote.core.Version
import io.github.leonmason.jitnote.data.AppUpdates
import io.github.leonmason.jitnote.data.NoteIndex
import io.github.leonmason.jitnote.data.Notebooks

sealed interface Screen {
    /** The current notebook's file tree. */
    data object Home : Screen

    /** Add, rename, remove and sync notebooks. */
    data object Notebooks : Screen
    data object Settings : Screen
    data object Accounts : Screen
    data object AddAccount : Screen
    data object NewNotebook : Screen
    data class Editor(val notebookId: String, val path: String, val startEditing: Boolean = false) : Screen
    data class History(val notebookId: String, val path: String) : Screen
    data class VersionPreview(val notebookId: String, val path: String, val version: Version) : Screen
    data class Conflicts(val notebookId: String) : Screen
    data class Image(val notebookId: String, val path: String) : Screen
}

/** A plain back stack; survives rotation as a ViewModel. */
class Navigator : ViewModel() {
    val stack = mutableStateListOf<Screen>(Screen.Home)

    /**
     * File tree state that should survive opening a note, per notebook: the highlighted path, the
     * loaded tree (so coming back doesn't flash empty) and the scroll position.
     */
    val highlighted = mutableStateMapOf<String, String>()
    val trees = mutableStateMapOf<String, List<NoteIndex.Entry>>()
    val treeScroll = mutableMapOf<String, LazyListState>()

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
fun JitnoteUi(notebooks: Notebooks, updates: AppUpdates, nav: Navigator = viewModel()) {
    BackHandler(enabled = nav.stack.size > 1) { nav.pop() }
    LaunchedEffect(Unit) { updates.checkOnLaunch() }
    val screen = nav.stack.last()
    // Each stack entry gets its own state; otherwise Folder("a") → Folder("a/b") would reuse
    // the parent's remembered file list.
    key(nav.stack.size, screen) { ScreenContent(notebooks, updates, nav, screen) }
    UpdateDialog(updates)
}

@Composable
private fun ScreenContent(notebooks: Notebooks, updates: AppUpdates, nav: Navigator, screen: Screen) {
    when (screen) {
        Screen.Home -> HomeScreen(notebooks, updates, nav)
        Screen.Notebooks -> NotebooksScreen(notebooks, nav)
        Screen.Settings -> SettingsScreen(notebooks, nav)
        Screen.Accounts -> AccountsScreen(notebooks, nav)
        Screen.AddAccount -> AddAccountScreen(notebooks, nav)
        Screen.NewNotebook -> NewNotebookScreen(notebooks, nav)
        is Screen.Editor -> EditorScreen(notebooks, nav, screen)
        is Screen.History -> HistoryScreen(notebooks, nav, screen)
        is Screen.VersionPreview -> VersionPreviewScreen(notebooks, nav, screen)
        is Screen.Conflicts -> ConflictsScreen(notebooks, nav, screen)
        is Screen.Image -> ImageViewerScreen(notebooks, nav, screen)
    }
}

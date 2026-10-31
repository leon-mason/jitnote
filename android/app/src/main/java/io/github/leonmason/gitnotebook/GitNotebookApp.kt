package io.github.leonmason.gitnotebook

import android.app.Application
import android.webkit.WebView
import io.github.leonmason.gitnotebook.core.GitEnvironment
import io.github.leonmason.gitnotebook.data.AppUpdates
import io.github.leonmason.gitnotebook.data.HostingApi
import io.github.leonmason.gitnotebook.data.Notebooks
import io.github.leonmason.gitnotebook.data.StateStore
import io.github.leonmason.gitnotebook.data.TokenVault
import java.io.File

class GitNotebookApp : Application() {
    lateinit var notebooks: Notebooks
        private set
    lateinit var updates: AppUpdates
        private set

    override fun onCreate() {
        super.onCreate()
        GitEnvironment.install(File(filesDir, "jgit"))
        if (BuildConfig.DEBUG) WebView.setWebContentsDebuggingEnabled(true)
        val store = StateStore(File(filesDir, "state.json"))
        notebooks = Notebooks(
            root = File(filesDir, "notebooks"),
            store = store,
            api = HostingApi(),
            vault = TokenVault(),
        )
        updates = AppUpdates(cacheDir, store, BuildConfig.VERSION_NAME)
    }
}

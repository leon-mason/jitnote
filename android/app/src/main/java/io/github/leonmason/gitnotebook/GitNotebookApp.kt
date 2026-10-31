package io.github.leonmason.gitnotebook

import android.app.Application
import android.webkit.WebView
import io.github.leonmason.gitnotebook.core.GitEnvironment
import io.github.leonmason.gitnotebook.data.HostingApi
import io.github.leonmason.gitnotebook.data.Notebooks
import io.github.leonmason.gitnotebook.data.StateStore
import io.github.leonmason.gitnotebook.data.TokenVault
import java.io.File

class GitNotebookApp : Application() {
    lateinit var notebooks: Notebooks
        private set

    override fun onCreate() {
        super.onCreate()
        GitEnvironment.install(File(filesDir, "jgit"))
        if (BuildConfig.DEBUG) WebView.setWebContentsDebuggingEnabled(true)
        notebooks = Notebooks(
            root = File(filesDir, "notebooks"),
            store = StateStore(File(filesDir, "state.json")),
            api = HostingApi(),
            vault = TokenVault(),
        )
    }
}

package io.github.leonmason.jitnote

import android.app.Application
import android.webkit.WebView
import io.github.leonmason.jitnote.core.GitEnvironment
import io.github.leonmason.jitnote.data.AppUpdates
import io.github.leonmason.jitnote.data.HostingApi
import io.github.leonmason.jitnote.data.Notebooks
import io.github.leonmason.jitnote.data.StateStore
import io.github.leonmason.jitnote.data.TokenVault
import java.io.File

class JitnoteApp : Application() {
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

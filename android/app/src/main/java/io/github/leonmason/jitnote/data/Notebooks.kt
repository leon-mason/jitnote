package io.github.leonmason.jitnote.data

import android.os.Build
import io.github.leonmason.jitnote.BuildConfig
import io.github.leonmason.jitnote.core.Author
import io.github.leonmason.jitnote.core.PendingConflict
import io.github.leonmason.jitnote.core.Side
import io.github.leonmason.jitnote.core.Credentials
import io.github.leonmason.jitnote.core.NotebookGit
import io.github.leonmason.jitnote.core.SyncException
import io.github.leonmason.jitnote.core.SyncResult
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.eclipse.jgit.lib.ProgressMonitor
import java.io.File
import java.time.Instant
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

sealed interface SyncState {
    data object Running : SyncState

    /** [seq] changes on every finished sync so the UI can show each result exactly once. */
    data class Finished(val seq: Long, val ok: Boolean, val message: String, val conflicts: Int) : SyncState
}

/** Everything the screens do with keys and notebooks. All Git work runs on IO, one operation per notebook at a time. */
class Notebooks(
    private val root: File,
    private val store: StateStore,
    private val api: HostingApi,
    private val vault: TokenVault,
) {
    val state: StateFlow<AppState> get() = store.state

    /** Files that both this device and the cloud changed, waiting for a choice before the sync goes on. */
    class PendingSync(
        val notebook: Notebook,
        val conflicts: List<PendingConflict>,
        /** Choices made in an earlier round that still apply (the cloud moved on while the user decided). */
        val choices: Map<String, Side>,
    )

    private val _pendingSync = MutableStateFlow<PendingSync?>(null)

    /** A sync that stopped to ask which side wins; the UI shows the question until it is answered. */
    val pendingSync: StateFlow<PendingSync?> = _pendingSync.asStateFlow()

    /** Outlives screens, so a sync keeps going when the user navigates away. */
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    private val locks = ConcurrentHashMap<String, Mutex>()
    private val _syncStates = MutableStateFlow<Map<String, SyncState>>(emptyMap())
    val syncStates: StateFlow<Map<String, SyncState>> = _syncStates.asStateFlow()
    private var syncSeq = 0L

    val device: String = Build.MODEL ?: "Android"

    fun notebook(id: String): Notebook? = state.value.notebooks.firstOrNull { it.id == id }

    fun account(id: String): Account? = state.value.accounts.firstOrNull { it.id == id }

    fun dir(notebook: Notebook) = File(root, notebook.dir)

    fun git(notebook: Notebook) = NotebookGit(dir(notebook))

    // ------------------------------------------------------------------ keys

    suspend fun addAccount(provider: Provider, token: String, username: String?, email: String?): Account =
        withContext(Dispatchers.IO) {
            val user = if (provider == Provider.OTHER) {
                val login = username!!.trim()
                HostingApi.User(login, email?.trim()?.takeIf { it.isNotEmpty() } ?: "$login@users.noreply.jitnote")
            } else {
                api.verify(provider, token.trim())
            }
            var saved: Account? = null
            store.update { s ->
                val existing = s.accounts.firstOrNull { it.provider == provider && it.login == user.login }
                val account = Account(
                    id = existing?.id ?: UUID.randomUUID().toString(),
                    provider = provider,
                    login = user.login,
                    email = user.email,
                    encryptedToken = vault.encrypt(token.trim()),
                    createdAt = existing?.createdAt ?: System.currentTimeMillis(),
                )
                saved = account
                s.copy(accounts = s.accounts.filterNot { it.id == account.id } + account)
            }
            saved!!
        }

    fun removeAccount(account: Account) {
        store.update { s -> s.copy(accounts = s.accounts.filterNot { it.id == account.id }) }
    }

    // ------------------------------------------------------------------ notebooks

    /** Creates a private repository in the cloud, downloads it and records the notebook. */
    suspend fun create(
        name: String,
        account: Account,
        repoPath: String,
        onProgress: (String) -> Unit,
    ): Notebook = withContext(Dispatchers.IO) {
        val token = vault.decrypt(account.encryptedToken)
        onProgress("正在云端创建笔记本…")
        var path = repoPath
        var repo: HostingApi.CreatedRepo? = null
        for (attempt in 1..3) {
            try {
                repo = api.createPrivateRepo(account.provider, token, name, path)
                break
            } catch (e: HostingApi.NameTakenException) {
                if (attempt == 3) throw e
                path = "$repoPath-${RepoNames.randomSuffix()}"
            }
        }
        val created = repo!!
        val notebook = download(name, account, created.cloneUrl, onProgress)
        val dir = dir(notebook)
        File(dir, ".jitnote").mkdirs()
        File(dir, ".jitnote/notebook.json").writeText(
            buildJsonObject {
                put("schema_version", 1)
                put("id", notebook.id)
                put("display_name", name)
                put("created_at", Instant.now().toString())
                put("app_version", "Jitnote Android ${BuildConfig.VERSION_NAME}")
            }.toString() + "\n",
        )
        withLock(notebook) { git(notebook).commitAll(author(account), device, "新建笔记本：$name") }
        sync(notebook)
        notebook
    }

    /** Repositories in [account], each marked with whether it is already a notebook on this phone. */
    suspend fun listRemote(account: Account): List<Pair<HostingApi.RemoteRepo, Boolean>> = withContext(Dispatchers.IO) {
        val local = state.value.notebooks.map { sameRepoKey(it.remoteUrl) }.toSet()
        api.listRepos(account.provider, vault.decrypt(account.encryptedToken))
            .map { it to (sameRepoKey(it.cloneUrl) in local) }
    }

    private fun sameRepoKey(url: String) = url.trim().removeSuffix("/").removeSuffix(".git").lowercase()

    /** Downloads an existing repository as a notebook. */
    suspend fun import(url: String, account: Account, name: String, onProgress: (String) -> Unit): Notebook =
        withContext(Dispatchers.IO) {
            val notebook = download(name, account, url.trim(), onProgress)
            val meta = File(dir(notebook), ".jitnote/notebook.json")
            if (name.isBlank() && meta.exists()) {
                val display = Regex("\"display_name\"\\s*:\\s*\"([^\"]+)\"").find(meta.readText())?.groupValues?.get(1)
                if (display != null) rename(notebook, display)
            }
            notebook(notebook.id)!!
        }

    private fun download(name: String, account: Account, url: String, onProgress: (String) -> Unit): Notebook {
        val id = UUID.randomUUID().toString()
        val notebook = Notebook(
            id = id,
            name = name.ifBlank { url.substringAfterLast('/').removeSuffix(".git") },
            accountId = account.id,
            remoteUrl = url,
            dir = id,
            createdAt = System.currentTimeMillis(),
        )
        onProgress("正在下载笔记本…")
        NotebookGit.clone(url, dir(notebook), credentials(account), ProgressReporter(onProgress))
        // A fresh download is, by definition, in sync with the cloud.
        val downloaded = notebook.copy(lastSyncAt = System.currentTimeMillis())
        store.update { s -> s.copy(notebooks = s.notebooks + downloaded) }
        return downloaded
    }

    fun rename(notebook: Notebook, name: String) = updateNotebook(notebook.id) { it.copy(name = name) }

    /** The notebook the home screen shows; falls back to the first when the chosen one is gone. */
    fun current(state: AppState): Notebook? =
        state.notebooks.firstOrNull { it.id == state.currentNotebookId } ?: state.notebooks.firstOrNull()

    fun setCurrent(notebookId: String) = store.update { it.copy(currentNotebookId = notebookId) }

    fun setFileSort(sort: NoteSort) = store.update { it.copy(fileSort = sort) }

    fun setExpandedFolders(notebookId: String, paths: Set<String>) =
        store.update { it.copy(expandedFolders = it.expandedFolders + (notebookId to paths)) }

    fun setDefaultViewMode(mode: ViewMode) = store.update { it.copy(defaultViewMode = mode) }

    fun setShowHiddenFiles(show: Boolean) = store.update { it.copy(showHiddenFiles = show) }

    fun setSyncOnLaunch(enabled: Boolean) = store.update { it.copy(syncOnLaunch = enabled) }

    /** Removes the notebook from this device only. The cloud repository is left alone. */
    suspend fun deleteLocal(notebook: Notebook) = withContext(Dispatchers.IO) {
        withLock(notebook) { dir(notebook).deleteRecursively() }
        store.update { s -> s.copy(notebooks = s.notebooks.filterNot { it.id == notebook.id }, expandedFolders = s.expandedFolders - notebook.id) }
        locks.remove(notebook.id)
    }

    suspend fun hasUnsyncedWork(notebook: Notebook): Boolean =
        withLock(notebook) { runCatching { git(notebook).hasUnsyncedWork() }.getOrDefault(true) }

    // ------------------------------------------------------------------ editing

    private val _unsynced = MutableStateFlow<Set<String>>(emptySet())

    /**
     * Notebooks with something that has not reached the cloud: edits on disk. Versions are only
     * recorded when syncing (design.md, "同步规则"), so this is what tells the user there is something to sync.
     */
    val unsynced: StateFlow<Set<String>> = _unsynced.asStateFlow()

    fun refreshUnsyncedInBackground(notebook: Notebook) {
        scope.launch { refreshUnsynced(notebook) }
    }

    suspend fun refreshUnsynced(notebook: Notebook) {
        // A failed check keeps what was shown.
        val dirty = runCatching { withLock(notebook) { git(notebook).hasUnsyncedWork() } }.getOrNull() ?: return
        _unsynced.update { if (dirty) it + notebook.id else it - notebook.id }
    }

    /**
     * Records a version of just [paths] before the app deletes or overwrites them: with no commit
     * between syncs, text that was never synced would otherwise be gone for good.
     */
    suspend fun keepVersion(notebook: Notebook, paths: List<String>) {
        val account = account(notebook.accountId) ?: return
        runCatching { withLock(notebook) { git(notebook).commitPaths(paths, author(account), device) } }
    }

    suspend fun <T> withLock(notebook: Notebook, block: () -> T): T = withContext(Dispatchers.IO) {
        locks.getOrPut(notebook.id) { Mutex() }.withLock { block() }
    }

    // ------------------------------------------------------------------ sync

    private val shownResults = mutableSetOf<Long>()

    /** True the first time a finished sync is shown, so its message appears once. */
    fun markShown(state: SyncState.Finished): Boolean = synchronized(shownResults) { shownResults.add(state.seq) }

    fun isSyncing(notebookId: String) = syncStates.value[notebookId] == SyncState.Running

    fun startSync(notebook: Notebook, announceUnchanged: Boolean = true) {
        if (isSyncing(notebook.id)) return
        scope.launch { sync(notebook, announceUnchanged = announceUnchanged) }
    }

    private var backgroundAt: Long? = null
    private var sawForeground = false
    /** Bumped on every background so a sync scheduled for the previous return is dropped. */
    private var foregroundEpoch = 0

    /** The app is no longer visible. A later [onForeground] may auto-sync. See design.md「同步规则」. */
    fun onBackground() {
        foregroundEpoch++
        // A stop that arrives before the first start (rotation, process setup) is not "the user left".
        if (sawForeground) backgroundAt = System.currentTimeMillis()
    }

    /**
     * The app is visible again: a cold start, or a return from the background.
     * Does nothing unless「启动时自动同步」is on.
     */
    fun onForeground() {
        val away = backgroundAt?.let { System.currentTimeMillis() - it }
        backgroundAt = null
        val handled = sawForeground
        sawForeground = true
        val notebook = current(store.state.value) ?: return
        val busy = isSyncing(notebook.id) || _pendingSync.value != null
        if (!AutoSync.shouldStart(store.state.value.syncOnLaunch, busy, true, away, handled)) return
        if (away == null) {
            startSync(notebook, announceUnchanged = false)
            return
        }
        // The save requested on the way out may complete only after this return. See AutoSync.RESUME_FLUSH_MS.
        val scheduled = foregroundEpoch
        scope.launch {
            delay(AutoSync.RESUME_FLUSH_MS)
            if (foregroundEpoch != scheduled) return@launch
            val current = current(store.state.value) ?: return@launch
            if (!store.state.value.syncOnLaunch || isSyncing(current.id) || _pendingSync.value != null) return@launch
            startSync(current, announceUnchanged = false)
        }
    }

    /** Goes on with a sync that asked a question, using the user's answers. */
    fun continueSync(choices: Map<String, Side>) {
        val pending = _pendingSync.value ?: return
        if (isSyncing(pending.notebook.id)) return
        _pendingSync.value = null
        scope.launch { sync(pending.notebook, choices) }
    }

    /** The user would rather not decide now. Nothing was merged or uploaded; the next sync asks again. */
    fun cancelPendingSync() {
        val pending = _pendingSync.value ?: return
        _pendingSync.value = null
        val message = "已取消同步。两边的修改都还在，下次同步时再选择。"
        _syncStates.update { it + (pending.notebook.id to SyncState.Finished(++syncSeq, false, message, 0)) }
    }

    private suspend fun sync(notebook: Notebook, choices: Map<String, Side> = emptyMap(), announceUnchanged: Boolean = true) {
        _syncStates.update { it + (notebook.id to SyncState.Running) }
        val finished = try {
            val account = account(notebook.accountId) ?: throw SyncException(SyncException.Kind.AUTH, "这个笔记本用的云端账号已断开，请重新连接")
            val result = withLock(notebook) { git(notebook).sync(credentials(account), author(account), device, choices) }
            if (result.pending.isNotEmpty()) {
                // Not finished: no "synced" time and no message, just the question.
                _pendingSync.value = PendingSync(notebook, result.pending, choices.filterKeys { k -> result.pending.any { it.path == k } })
                null
            } else {
                updateNotebook(notebook.id) { it.copy(lastSyncAt = System.currentTimeMillis(), lastSyncError = null) }
                // An automatic sync that changed nothing stays quiet. A manual one still says "已是最新".
                if (!announceUnchanged && result.resolved == 0 && !result.pulled && !result.pushed) null
                else SyncState.Finished(++syncSeq, true, describe(result), result.resolved)
            }
        } catch (e: Exception) {
            val message = (e as? SyncException)?.message ?: NotebookGit.classify(e).message ?: "同步失败"
            updateNotebook(notebook.id) { it.copy(lastSyncError = message) }
            SyncState.Finished(++syncSeq, false, message, 0)
        }
        _syncStates.update { if (finished != null) it + (notebook.id to finished) else it - notebook.id }
        refreshUnsynced(notebook)
    }

    private fun describe(result: SyncResult): String = when {
        result.resolved > 0 -> "已同步。${result.resolved} 个文件两边都改了，已按你的选择处理"
        result.pulled && result.pushed -> "已同步：收到云端修改，并上传了本机修改"
        result.pulled -> "已同步：收到云端修改"
        result.pushed -> "已同步：已上传本机修改"
        else -> "已是最新"
    }

    // ------------------------------------------------------------------ history

    suspend fun restore(notebook: Notebook, path: String, commit: String) {
        val account = account(notebook.accountId) ?: return
        withLock(notebook) { git(notebook).restore(path, commit, author(account), device) }
    }

    // ------------------------------------------------------------------ helpers

    private fun updateNotebook(id: String, transform: (Notebook) -> Notebook) {
        store.update { s -> s.copy(notebooks = s.notebooks.map { if (it.id == id) transform(it) else it }) }
    }

    private fun author(account: Account) = Author(account.login, account.email)

    private fun credentials(account: Account) = Credentials(account.login, vault.decrypt(account.encryptedToken))

    /** Turns JGit's progress callbacks into short status lines. */
    private class ProgressReporter(private val onProgress: (String) -> Unit) : ProgressMonitor {
        private var task = ""
        private var total = 0
        private var done = 0
        private var lastPercent = -1

        override fun start(totalTasks: Int) = Unit

        override fun beginTask(title: String, totalWork: Int) {
            task = title
            total = totalWork
            done = 0
            lastPercent = -1
        }

        override fun update(completed: Int) {
            done += completed
            if (total <= 0) return
            val percent = done * 100 / total
            if (percent != lastPercent) {
                lastPercent = percent
                onProgress("正在下载笔记本… $percent%")
            }
        }

        override fun endTask() = Unit

        override fun isCancelled() = false
    }
}

object RepoNames {
    /** Repository path derived from a display name; Chinese-only names get a random path. */
    fun fromName(name: String): String {
        val slug = name.lowercase()
            .replace(Regex("[^a-z0-9._-]+"), "-")
            .trim('-', '.', '_')
            .take(60)
        return if (slug.length >= 2 && slug[0].isLetter()) slug else "notes-${randomSuffix()}"
    }

    fun randomSuffix(): String = (1..6).map { "abcdefghijkmnpqrstuvwxyz23456789".random() }.joinToString("")

    fun isValid(path: String) = Regex("^[A-Za-z][A-Za-z0-9._-]{1,99}$").matches(path)
}

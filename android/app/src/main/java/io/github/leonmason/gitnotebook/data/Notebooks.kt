package io.github.leonmason.gitnotebook.data

import android.os.Build
import io.github.leonmason.gitnotebook.BuildConfig
import io.github.leonmason.gitnotebook.core.Author
import io.github.leonmason.gitnotebook.core.ConflictRecord
import io.github.leonmason.gitnotebook.core.Credentials
import io.github.leonmason.gitnotebook.core.NotebookGit
import io.github.leonmason.gitnotebook.core.SyncException
import io.github.leonmason.gitnotebook.core.SyncResult
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
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
                HostingApi.User(login, email?.trim()?.takeIf { it.isNotEmpty() } ?: "$login@users.noreply.gitnotebook")
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
        File(dir, ".gitnote").mkdirs()
        File(dir, ".gitnote/notebook.json").writeText(
            buildJsonObject {
                put("schema_version", 1)
                put("id", notebook.id)
                put("display_name", name)
                put("created_at", Instant.now().toString())
                put("app_version", "GitNotebook Android ${BuildConfig.VERSION_NAME}")
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
            val meta = File(dir(notebook), ".gitnote/notebook.json")
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

    /** Removes the notebook from this device only. The cloud repository is left alone. */
    suspend fun deleteLocal(notebook: Notebook) = withContext(Dispatchers.IO) {
        withLock(notebook) { dir(notebook).deleteRecursively() }
        store.update { s -> s.copy(notebooks = s.notebooks.filterNot { it.id == notebook.id }) }
        locks.remove(notebook.id)
    }

    suspend fun hasUnsyncedWork(notebook: Notebook): Boolean =
        withLock(notebook) { runCatching { git(notebook).hasUnsyncedWork() }.getOrDefault(true) }

    // ------------------------------------------------------------------ editing

    /** Commits whatever changed in the working copy, e.g. after leaving the editor. */
    fun commitInBackground(notebook: Notebook) {
        scope.launch { commit(notebook) }
    }

    suspend fun commit(notebook: Notebook, message: String? = null): Boolean {
        val account = account(notebook.accountId) ?: return false
        return withLock(notebook) { git(notebook).commitAll(author(account), device, message) }
    }

    suspend fun <T> withLock(notebook: Notebook, block: () -> T): T = withContext(Dispatchers.IO) {
        locks.getOrPut(notebook.id) { Mutex() }.withLock { block() }
    }

    // ------------------------------------------------------------------ sync

    private val shownResults = mutableSetOf<Long>()

    /** True the first time a finished sync is shown, so its message appears once. */
    fun markShown(state: SyncState.Finished): Boolean = synchronized(shownResults) { shownResults.add(state.seq) }

    fun isSyncing(notebookId: String) = syncStates.value[notebookId] == SyncState.Running

    fun startSync(notebook: Notebook) {
        if (isSyncing(notebook.id)) return
        scope.launch { sync(notebook) }
    }

    private suspend fun sync(notebook: Notebook) {
        _syncStates.update { it + (notebook.id to SyncState.Running) }
        val finished = try {
            val account = account(notebook.accountId) ?: throw SyncException(SyncException.Kind.AUTH, "这个笔记本用的云端账号已断开，请重新连接")
            val result = withLock(notebook) { git(notebook).sync(credentials(account), author(account), device) }
            updateNotebook(notebook.id) { it.copy(lastSyncAt = System.currentTimeMillis(), lastSyncError = null) }
            SyncState.Finished(++syncSeq, true, describe(result), result.conflicts.size)
        } catch (e: Exception) {
            val message = (e as? SyncException)?.message ?: NotebookGit.classify(e).message ?: "同步失败"
            updateNotebook(notebook.id) { it.copy(lastSyncError = message) }
            SyncState.Finished(++syncSeq, false, message, 0)
        }
        _syncStates.update { it + (notebook.id to finished) }
    }

    private fun describe(result: SyncResult): String = when {
        result.conflicts.isNotEmpty() -> "已同步。${result.conflicts.size} 个文件两边都改了，已采用较新版本"
        result.pulled && result.pushed -> "已同步：收到云端修改，并上传了本机修改"
        result.pulled -> "已同步：收到云端修改"
        result.pushed -> "已同步：已上传本机修改"
        else -> "已是最新"
    }

    // ------------------------------------------------------------------ conflicts

    suspend fun conflicts(notebook: Notebook): List<ConflictRecord> = withLock(notebook) { git(notebook).conflicts() }

    suspend fun useOtherVersion(notebook: Notebook, record: ConflictRecord) {
        val account = account(notebook.accountId) ?: return
        withLock(notebook) { git(notebook).useOtherVersion(record, author(account), device) }
    }

    suspend fun dismissConflict(notebook: Notebook, record: ConflictRecord) =
        withLock(notebook) { git(notebook).dismissConflict(record.path) }

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

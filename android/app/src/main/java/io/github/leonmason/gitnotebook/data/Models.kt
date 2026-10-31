package io.github.leonmason.gitnotebook.data

import kotlinx.serialization.Serializable

@Serializable
enum class Provider(val label: String) {
    GITHUB("GitHub"),
    GITEE("Gitee"),
    OTHER("其他 Git 服务"),
    ;

    /** Whether the app can create repositories on this host through its API. */
    val canCreateRepos get() = this != OTHER
}

/** A key the user pasted. The token itself is stored encrypted, see [TokenVault]. */
@Serializable
data class Account(
    val id: String,
    val provider: Provider,
    /** Platform login; also the HTTPS user name. */
    val login: String,
    /** Email written into commits. */
    val email: String,
    val encryptedToken: String,
    val createdAt: Long,
)

@Serializable
data class Notebook(
    val id: String,
    val name: String,
    val accountId: String,
    val remoteUrl: String,
    /** Working copy directory name under the app's notebooks folder. */
    val dir: String,
    val createdAt: Long,
    val lastSyncAt: Long? = null,
    val lastSyncError: String? = null,
)

@Serializable
data class AppState(
    val accounts: List<Account> = emptyList(),
    val notebooks: List<Notebook> = emptyList(),
    /** The notebook the home screen shows; the first one when unset or removed. */
    val currentNotebookId: String? = null,
    val noteSort: NoteSort = NoteSort.MODIFIED_DESC,
    /** List files and folders starting with "." (never .git), see [NoteIndex.isHidden]. */
    val showHiddenFiles: Boolean = false,
    /** Last successful check for a new app version, see [AppUpdates]. */
    val lastUpdateCheckAt: Long? = null,
)

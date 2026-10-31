package io.github.leonmason.gitnotebook.core

import kotlinx.serialization.Serializable

/** Who commits: written into every commit made on this device. */
data class Author(val name: String, val email: String)

/** HTTPS credentials. For GitHub / Gitee the password is the personal access token. */
data class Credentials(val username: String, val password: String)

enum class Side { LOCAL, REMOTE }

/**
 * A file that both this device and the cloud changed since the last sync.
 * The newer version was kept in the working tree; the other one is still in history
 * ([otherCommit]) and can be brought back with [NotebookGit.useOtherVersion].
 */
@Serializable
data class ConflictRecord(
    val path: String,
    val kept: Side,
    /** Author time (ms) of the last change on the kept side. */
    val keptTime: Long,
    val otherTime: Long,
    /** Blob of the version that was not kept; null when that side deleted the file. */
    val otherBlob: String?,
    val otherCommit: String,
    val createdAt: Long,
)

data class SyncResult(
    /** Changes from the cloud were brought in. */
    val pulled: Boolean,
    /** Local commits were uploaded. */
    val pushed: Boolean,
    val conflicts: List<ConflictRecord>,
)

data class Version(
    val commit: String,
    val time: Long,
    val message: String,
    val author: String,
)

class SyncException(val kind: Kind, message: String, cause: Throwable? = null) : Exception(message, cause) {
    enum class Kind { AUTH, NETWORK, NOT_FOUND, REJECTED, OTHER }
}

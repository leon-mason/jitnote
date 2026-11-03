package io.github.leonmason.jitnote.core

/** Who commits: written into every commit made on this device. */
data class Author(val name: String, val email: String)

/** HTTPS credentials. For GitHub / Gitee the password is the personal access token. */
data class Credentials(val username: String, val password: String)

enum class Side { LOCAL, REMOTE }

/**
 * A file that both this device and the cloud changed since the last sync, or that one side deleted
 * while the other changed it. Nothing is merged until the user says which side wins; the side that
 * loses stays in history, because the merge commit has both sides as parents.
 */
class PendingConflict(
    val path: String,
    /** Content on this device; null when it was deleted here. */
    val local: ByteArray?,
    /** Content in the cloud; null when it was deleted there. */
    val cloud: ByteArray?,
) {
    override fun equals(other: Any?) =
        other is PendingConflict && path == other.path && local.contentEqualsOrNull(other.local) && cloud.contentEqualsOrNull(other.cloud)

    override fun hashCode() = path.hashCode()

    private fun ByteArray?.contentEqualsOrNull(other: ByteArray?) = if (this == null) other == null else other != null && contentEquals(other)
}

data class SyncResult(
    /** Changes from the cloud were brought in. */
    val pulled: Boolean,
    /** Local commits were uploaded. */
    val pushed: Boolean,
    /** Files that were both changed and settled with the user's choices during this sync. */
    val resolved: Int,
    /**
     * Conflicts that need a choice. When there are any, nothing was merged or uploaded: ask the user,
     * then sync again with the choices.
     */
    val pending: List<PendingConflict>,
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

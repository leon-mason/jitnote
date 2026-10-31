package io.github.leonmason.gitnotebook.core

import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import org.eclipse.jgit.api.Git
import org.eclipse.jgit.api.MergeCommand
import org.eclipse.jgit.api.MergeResult
import org.eclipse.jgit.api.ResetCommand
import org.eclipse.jgit.api.errors.TransportException
import org.eclipse.jgit.lib.Constants
import org.eclipse.jgit.lib.NullProgressMonitor
import org.eclipse.jgit.lib.ObjectId
import org.eclipse.jgit.lib.PersonIdent
import org.eclipse.jgit.lib.ProgressMonitor
import org.eclipse.jgit.lib.Repository
import org.eclipse.jgit.lib.RepositoryState
import org.eclipse.jgit.revwalk.RevWalk
import org.eclipse.jgit.revwalk.filter.RevFilter
import org.eclipse.jgit.transport.CredentialsProvider
import org.eclipse.jgit.transport.RefSpec
import org.eclipse.jgit.transport.RemoteRefUpdate
import org.eclipse.jgit.transport.UsernamePasswordCredentialsProvider
import org.eclipse.jgit.treewalk.TreeWalk
import java.io.File
import java.net.ConnectException
import java.net.NoRouteToHostException
import java.net.SocketTimeoutException
import java.net.UnknownHostException

/**
 * One notebook = one ordinary Git working copy. Everything the app does to a notebook
 * goes through here, and everything ends up as plain Git objects, so any other Git
 * client (or an AI tool on a desktop) can work on the same repository.
 *
 * Sync rules:
 * - commit local changes → fetch → merge (never rebase) → push; never force-push.
 * - a file changed on both sides keeps the version whose last change is newer
 *   (ties go to the cloud); the other version stays in history and is recorded as a
 *   [ConflictRecord] so the user can switch to it.
 * - a file deleted on one side and changed on the other is kept.
 *
 * Not thread-safe: callers serialize access per notebook.
 */
class NotebookGit(val workTree: File) {

    fun hasLocalChanges(): Boolean = withGit { !it.status().call().isClean }

    /** True when something on this device has not reached the cloud yet. */
    fun hasUnsyncedWork(): Boolean = withGit { git ->
        if (!git.status().call().isClean) return@withGit true
        val repo = git.repository
        val head = repo.resolve(Constants.HEAD) ?: return@withGit false
        val remote = repo.exactRef(remoteRef(repo.branch))?.objectId ?: return@withGit true
        !isAncestor(repo, head, remote)
    }

    /** Commits every change in the working tree. Returns false when there was nothing to commit. */
    fun commitAll(author: Author, device: String, message: String? = null): Boolean = withGit { git ->
        applyIdentity(git.repository, author)
        commitAllInternal(git, author, device, message)
    }

    fun sync(credentials: Credentials?, author: Author, device: String): SyncResult =
        try {
            withGit { git -> syncInternal(git, credentials?.toProvider(), author, device) }
        } catch (e: Exception) {
            throw classify(e)
        }

    /** Versions of [path], newest first. */
    fun history(path: String, max: Int = 200): List<Version> = withGit { git ->
        if (git.repository.resolve(Constants.HEAD) == null) return@withGit emptyList()
        git.log().addPath(path).setMaxCount(max).call().map {
            Version(it.name, it.authorIdent.`when`.time, it.shortMessage, it.authorIdent.name)
        }
    }

    /** Content of [path] at [commit], or null if the file does not exist there. */
    fun readAt(commit: String, path: String): ByteArray? = withGit { readAt(it.repository, commit, path) }

    fun readBlob(blob: String): ByteArray = withGit { it.repository.open(ObjectId.fromString(blob)).bytes }

    /** Overwrites [path] with its content at [commit] and commits that as a new change. */
    fun restore(path: String, commit: String, author: Author, device: String): Boolean = withGit { git ->
        writeOrDelete(path, readAt(git.repository, commit, path))
        applyIdentity(git.repository, author)
        commitAllInternal(git, author, device, "恢复历史版本：${title(path)}")
    }

    fun conflicts(): List<ConflictRecord> {
        val file = conflictFile()
        if (!file.exists()) return emptyList()
        return runCatching { json.decodeFromString<List<ConflictRecord>>(file.readText()) }.getOrDefault(emptyList())
    }

    fun dismissConflict(path: String) = saveConflicts(conflicts().filterNot { it.path == path })

    /** Replaces the kept version of a conflicted file with the one that was set aside. */
    fun useOtherVersion(record: ConflictRecord, author: Author, device: String) {
        withGit { git ->
            writeOrDelete(record.path, record.otherBlob?.let { git.repository.open(ObjectId.fromString(it)).bytes })
            applyIdentity(git.repository, author)
            commitAllInternal(git, author, device, "改用另一个版本：${title(record.path)}")
        }
        dismissConflict(record.path)
    }

    // ---------------------------------------------------------------- sync internals

    private fun syncInternal(git: Git, provider: CredentialsProvider?, author: Author, device: String): SyncResult {
        val repo = git.repository
        recover(git)
        applyIdentity(repo, author)
        commitAllInternal(git, author, device, null)
        val branch = repo.branch
        var pulled = false
        val conflicts = mutableListOf<ConflictRecord>()
        repeat(MAX_ATTEMPTS) {
            git.fetch()
                .setRemote(REMOTE)
                .setCredentialsProvider(provider)
                .setRemoveDeletedRefs(true)
                .setTimeout(TIMEOUT_SECONDS)
                .call()
            val remote = repo.exactRef(remoteRef(branch))?.objectId
            if (remote != null) {
                val merge = mergeRemote(git, remote, author, device)
                pulled = pulled || merge.changed
                conflicts += merge.conflicts
            }
            val local = repo.resolve(Constants.HEAD)
            if (local == null || local == remote) return SyncResult(pulled, false, conflicts)
            if (push(git, branch, provider)) {
                ensureUpstream(repo, branch)
                return SyncResult(pulled, true, conflicts)
            }
            // Someone pushed between our fetch and push: fetch and merge again.
        }
        throw SyncException(SyncException.Kind.REJECTED, "云端在同步期间不断变化，请稍后再试")
    }

    private class MergeOutcome(val changed: Boolean, val conflicts: List<ConflictRecord>)

    private fun mergeRemote(git: Git, theirs: ObjectId, author: Author, device: String): MergeOutcome {
        val repo = git.repository
        val head = repo.resolve(Constants.HEAD)
        if (head == null) {
            // Nothing committed on this device yet: adopt the cloud's history as is.
            val update = repo.updateRef(repo.fullBranch)
            update.setNewObjectId(theirs)
            update.update()
            git.reset().setMode(ResetCommand.ResetType.HARD).call()
            return MergeOutcome(true, emptyList())
        }
        if (isAncestor(repo, theirs, head)) return MergeOutcome(false, emptyList())

        val result = git.merge()
            .include(theirs)
            .setFastForward(MergeCommand.FastForwardMode.FF)
            .setCommit(true)
            .setMessage(commitMessage("同步：合并云端修改", device))
            .call()
        return when {
            result.mergeStatus == MergeResult.MergeStatus.CONFLICTING ->
                MergeOutcome(true, resolveConflicts(git, head, theirs, author, device))
            result.mergeStatus.isSuccessful -> MergeOutcome(true, emptyList())
            // Typically a file was written while syncing; JGit left the working tree untouched.
            else -> throw SyncException(SyncException.Kind.OTHER, "有文件正在被修改，请稍后再同步（${result.mergeStatus}）")
        }
    }

    private fun resolveConflicts(
        git: Git,
        ours: ObjectId,
        theirs: ObjectId,
        author: Author,
        device: String,
    ): List<ConflictRecord> {
        val repo = git.repository
        val base = mergeBase(repo, ours, theirs)

        // Stage 2 = this device, stage 3 = cloud. A missing stage means that side deleted the file.
        val stages = linkedMapOf<String, Array<ObjectId?>>()
        val index = repo.readDirCache()
        for (i in 0 until index.entryCount) {
            val entry = index.getEntry(i)
            if (entry.stage > 0) stages.getOrPut(entry.pathString) { arrayOfNulls(4) }[entry.stage] = entry.objectId
        }

        val now = System.currentTimeMillis()
        val records = mutableListOf<ConflictRecord>()
        for ((path, stage) in stages) {
            val oursBlob = stage[2]
            val theirsBlob = stage[3]
            if (oursBlob == null && theirsBlob == null) continue
            val oursTime = lastChange(git, ours, base, path)
            val theirsTime = lastChange(git, theirs, base, path)
            val keepLocal = when {
                oursBlob == null -> false
                theirsBlob == null -> true
                else -> oursTime > theirsTime
            }
            val kept = if (keepLocal) oursBlob else theirsBlob
            writeOrDelete(path, repo.open(kept!!).bytes)
            records += ConflictRecord(
                path = path,
                kept = if (keepLocal) Side.LOCAL else Side.REMOTE,
                keptTime = if (keepLocal) oursTime else theirsTime,
                otherTime = if (keepLocal) theirsTime else oursTime,
                otherBlob = (if (keepLocal) theirsBlob else oursBlob)?.name,
                otherCommit = (if (keepLocal) theirs else ours).name,
                createdAt = now,
            )
        }

        val add = git.add()
        stages.keys.forEach { add.addFilepattern(it) }
        add.call()
        val ident = PersonIdent(author.name, author.email)
        git.commit()
            .setMessage(commitMessage("同步：合并云端修改（${records.size} 个文件两边都改了，已采用较新版本）", device))
            .setAuthor(ident)
            .setCommitter(ident)
            .call()

        saveConflicts(conflicts().filterNot { old -> records.any { it.path == old.path } } + records)
        return records
    }

    /** Author time (ms) of the newest commit on [tip] that touched [path] after [base]; 0 if none. */
    private fun lastChange(git: Git, tip: ObjectId, base: ObjectId?, path: String): Long {
        val log = git.log().add(tip).addPath(path).setMaxCount(1)
        if (base != null) log.not(base)
        return log.call().firstOrNull()?.authorIdent?.`when`?.time ?: 0L
    }

    private fun push(git: Git, branch: String, provider: CredentialsProvider?): Boolean {
        val ref = Constants.R_HEADS + branch
        val results = git.push()
            .setRemote(REMOTE)
            .setRefSpecs(RefSpec("$ref:$ref"))
            .setCredentialsProvider(provider)
            .setTimeout(TIMEOUT_SECONDS)
            .call()
        for (result in results) {
            for (update in result.remoteUpdates) {
                when (update.status) {
                    RemoteRefUpdate.Status.OK, RemoteRefUpdate.Status.UP_TO_DATE -> Unit
                    RemoteRefUpdate.Status.REJECTED_NONFASTFORWARD,
                    RemoteRefUpdate.Status.REJECTED_REMOTE_CHANGED -> return false
                    else -> throw SyncException(
                        SyncException.Kind.REJECTED,
                        "云端拒绝了上传：${update.message ?: update.status}",
                    )
                }
            }
        }
        return true
    }

    /** Leaves the repository in a clean state after a crash in the middle of a previous sync. */
    private fun recover(git: Git) {
        val repo = git.repository
        File(repo.directory, "index.lock").delete()
        if (repo.repositoryState != RepositoryState.SAFE) {
            // Abort the unfinished merge. Local work was committed before merging, so nothing is lost.
            git.reset().setMode(ResetCommand.ResetType.HARD).call()
            repo.writeMergeHeads(null)
            repo.writeMergeCommitMsg(null)
        }
    }

    private fun commitAllInternal(git: Git, author: Author, device: String, message: String?): Boolean {
        if (git.status().call().isClean) return false
        git.add().addFilepattern(".").call()
        git.add().addFilepattern(".").setUpdate(true).call()
        val staged = git.status().call()
        val summary = message ?: describeChanges(staged.added, staged.changed, staged.removed) ?: return false
        val ident = PersonIdent(author.name, author.email)
        git.commit()
            .setMessage(commitMessage(summary, device))
            .setAuthor(ident)
            .setCommitter(ident)
            .call()
        return true
    }

    // ---------------------------------------------------------------- helpers

    private inline fun <T> withGit(block: (Git) -> T): T = Git.open(workTree).use(block)

    private fun writeOrDelete(path: String, content: ByteArray?) {
        val file = File(workTree, path)
        if (content == null) {
            file.delete()
        } else {
            file.parentFile?.mkdirs()
            file.writeBytes(content)
        }
    }

    private fun conflictFile() = File(workTree, ".git/gitnotebook/conflicts.json")

    private fun saveConflicts(list: List<ConflictRecord>) {
        val file = conflictFile()
        if (list.isEmpty()) {
            file.delete()
            return
        }
        file.parentFile?.mkdirs()
        file.writeText(json.encodeToString(list))
    }

    companion object {
        const val REMOTE = "origin"
        const val DEFAULT_BRANCH = "main"
        private const val TIMEOUT_SECONDS = 60
        private const val MAX_ATTEMPTS = 3
        private val json = Json { ignoreUnknownKeys = true }

        /** Downloads [url] into [dir]. Works for empty repositories too. */
        fun clone(
            url: String,
            dir: File,
            credentials: Credentials?,
            monitor: ProgressMonitor = NullProgressMonitor.INSTANCE,
        ): NotebookGit {
            try {
                Git.cloneRepository()
                    .setURI(url)
                    .setDirectory(dir)
                    .setCredentialsProvider(credentials?.toProvider())
                    .setProgressMonitor(monitor)
                    .setTimeout(TIMEOUT_SECONDS)
                    .call()
                    .use { prepare(it.repository) }
            } catch (e: Exception) {
                dir.deleteRecursively()
                throw classify(e)
            }
            return NotebookGit(dir)
        }

        private fun prepare(repo: Repository) {
            val config = repo.config
            // Android storage does not keep the executable bit reliably; ignore mode changes.
            config.setBoolean("core", null, "filemode", false)
            config.save()
            if (repo.resolve(Constants.HEAD) == null && repo.refDatabase.refs.none { it.name.startsWith(Constants.R_REFS) }) {
                // Empty cloud repository: start on "main" like GitHub / Gitee do.
                repo.updateRef(Constants.HEAD).link(Constants.R_HEADS + DEFAULT_BRANCH)
            }
        }

        private fun remoteRef(branch: String) = "${Constants.R_REMOTES}$REMOTE/$branch"

        private fun Credentials.toProvider() = UsernamePasswordCredentialsProvider(username, password)

        private fun applyIdentity(repo: Repository, author: Author) {
            val config = repo.config
            if (config.getString("user", null, "name") == author.name &&
                config.getString("user", null, "email") == author.email
            ) return
            config.setString("user", null, "name", author.name)
            config.setString("user", null, "email", author.email)
            config.save()
        }

        private fun ensureUpstream(repo: Repository, branch: String) {
            val config = repo.config
            if (config.getString("branch", branch, "remote") != null) return
            config.setString("branch", branch, "remote", REMOTE)
            config.setString("branch", branch, "merge", Constants.R_HEADS + branch)
            config.save()
        }

        private fun isAncestor(repo: Repository, ancestor: ObjectId, of: ObjectId): Boolean =
            RevWalk(repo).use { it.isMergedInto(it.parseCommit(ancestor), it.parseCommit(of)) }

        private fun mergeBase(repo: Repository, a: ObjectId, b: ObjectId): ObjectId? =
            RevWalk(repo).use { walk ->
                walk.revFilter = RevFilter.MERGE_BASE
                walk.markStart(walk.parseCommit(a))
                walk.markStart(walk.parseCommit(b))
                walk.next()?.copy()
            }

        private fun readAt(repo: Repository, commit: String, path: String): ByteArray? =
            RevWalk(repo).use { walk ->
                val tree = walk.parseCommit(ObjectId.fromString(commit)).tree
                TreeWalk.forPath(repo, path, tree)?.use { repo.open(it.getObjectId(0)).bytes }
            }

        internal fun commitMessage(summary: String, device: String) = "$summary\n\n来自 记特 · $device"

        /** Human-readable commit summary such as "编辑：读书笔记". */
        internal fun describeChanges(added: Set<String>, changed: Set<String>, removed: Set<String>): String? {
            val total = added.size + changed.size + removed.size
            if (total == 0) return null
            if (added.size == 1 && removed.size == 1 && changed.isEmpty()) {
                return "重命名：${title(removed.first())} → ${title(added.first())}"
            }
            if (total == 1) {
                return when {
                    added.isNotEmpty() -> "新建：${title(added.first())}"
                    changed.isNotEmpty() -> "编辑：${title(changed.first())}"
                    else -> "删除：${title(removed.first())}"
                }
            }
            val names = (changed + added + removed).map(::title).distinct()
            val more = if (names.size > 3) " 等" else ""
            return "更新 $total 个文件：${names.take(3).joinToString("、")}$more"
        }

        internal fun title(path: String): String {
            val name = path.substringAfterLast('/')
            return listOf(".md", ".markdown").firstOrNull { name.endsWith(it, ignoreCase = true) }
                ?.let { name.dropLast(it.length) } ?: name
        }

        internal fun classify(e: Throwable): SyncException {
            if (e is SyncException) return e
            val chain = generateSequence(e) { it.cause }.toList()
            val text = chain.joinToString(" | ") { it.message.orEmpty() }.lowercase()
            return when {
                chain.any {
                    it is UnknownHostException || it is SocketTimeoutException ||
                        it is ConnectException || it is NoRouteToHostException
                } -> SyncException(SyncException.Kind.NETWORK, "网络连接失败，请检查网络后重试", e)
                // Android refuses plain http:// unless allowed; not an account problem.
                "cleartext" in text ->
                    SyncException(SyncException.Kind.NETWORK, "为了安全，只支持 https:// 开头的地址", e)
                listOf("not authorized", "authentication", "not permitted", "401", "403").any { it in text } ->
                    SyncException(SyncException.Kind.AUTH, "账号授权无效或已过期，请到「云端账号」里重新连接", e)
                listOf("not found", "404").any { it in text } ->
                    SyncException(SyncException.Kind.NOT_FOUND, "找不到云端的笔记本，可能已被删除，或这个账号没有权限", e)
                chain.any { it is TransportException } ->
                    SyncException(SyncException.Kind.NETWORK, "连接云端失败：${e.message}", e)
                else -> SyncException(SyncException.Kind.OTHER, e.message ?: e.javaClass.simpleName, e)
            }
        }
    }
}

package io.github.leonmason.jitnote.core

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
import org.eclipse.jgit.merge.MergeStrategy
import org.eclipse.jgit.merge.ResolveMerger
import org.eclipse.jgit.revwalk.RevCommit
import org.eclipse.jgit.revwalk.RevSort
import org.eclipse.jgit.revwalk.RevWalk
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
 * - a file changed on both sides (or deleted on one and changed on the other) is never decided by
 *   the app: [sync] stops, before touching anything, and reports the file as a [PendingConflict];
 *   the caller asks the user and syncs again with the choices. The side that loses stays in history.
 * - another program's `index.lock` or unfinished merge is never cleaned up (see [prepareForSync]).
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

    /** [choices] settles conflicts a previous call reported in [SyncResult.pending]: which side wins, by path. */
    fun sync(credentials: Credentials?, author: Author, device: String, choices: Map<String, Side> = emptyMap()): SyncResult =
        try {
            withGit { git -> syncInternal(git, credentials?.toProvider(), author, device, choices) }
        } catch (e: Exception) {
            throw classify(e)
        }

    /**
     * Versions of [path], newest first: every commit whose [path] differs from all of its parents.
     * Not `git log -- path`: that drops the side of a merge that the merged file is identical to, which
     * would hide exactly the version the user chose not to keep (design.md, "同步规则" step 4).
     */
    fun history(path: String, max: Int = 200): List<Version> = withGit { git ->
        val repo = git.repository
        val head = repo.resolve(Constants.HEAD) ?: return@withGit emptyList()
        RevWalk(repo).use { walk ->
            walk.sort(RevSort.TOPO)
            walk.sort(RevSort.COMMIT_TIME_DESC, true)
            walk.markStart(walk.parseCommit(head))
            val versions = mutableListOf<Version>()
            for (commit in walk) {
                if (versions.size >= max) break
                if (!touches(repo, walk, commit, path)) continue
                versions += Version(commit.name, commit.authorIdent.`when`.time, commit.shortMessage, commit.authorIdent.name)
            }
            versions
        }
    }

    /** Content of [path] at [commit], or null if the file does not exist there. */
    fun readAt(commit: String, path: String): ByteArray? = withGit { readAt(it.repository, commit, path) }

    fun readBlob(blob: String): ByteArray = withGit { it.repository.open(ObjectId.fromString(blob)).bytes }

    /**
     * Overwrites [path] with its content at [commit]. What is there now is recorded first (just this
     * file), so restoring never loses the current text; the restored text goes in with the next sync.
     */
    fun restore(path: String, commit: String, author: Author, device: String) = withGit { git ->
        val content = readAt(git.repository, commit, path)
        applyIdentity(git.repository, author)
        commitPathsInternal(git, listOf(path), author, device, null)
        writeOrDelete(path, content)
    }

    /**
     * Commits only [paths] (files, or folders with everything under them); every other change stays
     * uncommitted, and so does whatever another tool has staged. Returns false when those paths have
     * nothing new. Used to keep a version of something before the app deletes or overwrites it.
     */
    fun commitPaths(paths: List<String>, author: Author, device: String, message: String? = null): Boolean =
        withGit { git ->
            applyIdentity(git.repository, author)
            commitPathsInternal(git, paths, author, device, message)
        }

    // ---------------------------------------------------------------- sync internals

    private fun syncInternal(
        git: Git,
        provider: CredentialsProvider?,
        author: Author,
        device: String,
        choices: Map<String, Side>,
    ): SyncResult {
        prepareForSync(git)
        try {
            return runSync(git, provider, author, device, choices)
        } finally {
            // Keep the marker when a failed sync left a merge behind, so the next sync still recognizes it as ours.
            if (git.repository.repositoryState == RepositoryState.SAFE) syncMarker().delete()
        }
    }

    private fun runSync(git: Git, provider: CredentialsProvider?, author: Author, device: String, choices: Map<String, Side>): SyncResult {
        val repo = git.repository
        applyIdentity(repo, author)
        // Records of earlier versions, which kept the newer side and let people switch afterwards. Unused now.
        File(workTree, LEGACY_CONFLICT_FILE).delete()
        commitAllInternal(git, author, device, null)
        val branch = repo.branch
        var pulled = false
        var resolved = 0
        repeat(MAX_ATTEMPTS) {
            git.fetch()
                .setRemote(REMOTE)
                .setCredentialsProvider(provider)
                .setRemoveDeletedRefs(true)
                .setTimeout(TIMEOUT_SECONDS)
                .call()
            val remote = repo.exactRef(remoteRef(branch))?.objectId
            if (remote != null) {
                val merge = mergeRemote(git, remote, author, device, choices)
                // Stop before touching anything: the working tree is left as it was while the user decides.
                if (merge.pending.isNotEmpty()) return SyncResult(pulled, false, resolved, merge.pending)
                pulled = pulled || merge.changed
                resolved += merge.resolved
            }
            val local = repo.resolve(Constants.HEAD)
            if (local == null || local == remote) return SyncResult(pulled, false, resolved, emptyList())
            if (push(git, branch, provider)) {
                ensureUpstream(repo, branch)
                return SyncResult(pulled, true, resolved, emptyList())
            }
            // Someone pushed between our fetch and push: fetch and merge again.
        }
        throw SyncException(SyncException.Kind.REJECTED, "云端在同步期间不断变化，请稍后再试")
    }

    private class MergeOutcome(val changed: Boolean, val resolved: Int, val pending: List<PendingConflict>)

    private fun mergeRemote(git: Git, theirs: ObjectId, author: Author, device: String, choices: Map<String, Side>): MergeOutcome {
        val repo = git.repository
        val head = repo.resolve(Constants.HEAD)
        if (head == null) {
            // Nothing committed on this device yet: adopt the cloud's history as is.
            val update = repo.updateRef(repo.fullBranch)
            update.setNewObjectId(theirs)
            update.update()
            git.reset().setMode(ResetCommand.ResetType.HARD).call()
            return MergeOutcome(true, 0, emptyList())
        }
        if (isAncestor(repo, theirs, head)) return MergeOutcome(false, 0, emptyList())

        // Find out first, in memory, whether both sides touched the same thing. Merging for real would
        // write conflict markers into the notebook folder, where another program could read them.
        if (!isAncestor(repo, head, theirs)) {
            val conflicts = findConflicts(repo, head, theirs)
            if (conflicts.any { it.path !in choices }) return MergeOutcome(false, 0, conflicts)
        }

        val result = git.merge()
            .include(theirs)
            .setFastForward(MergeCommand.FastForwardMode.FF)
            .setCommit(true)
            .setMessage(commitMessage("同步：合并云端修改", device))
            .call()
        return when {
            result.mergeStatus == MergeResult.MergeStatus.CONFLICTING ->
                MergeOutcome(true, resolveConflicts(git, head, theirs, author, device, choices), emptyList())
            result.mergeStatus.isSuccessful -> MergeOutcome(true, 0, emptyList())
            // Typically a file was written while syncing; JGit left the working tree untouched.
            else -> throw SyncException(SyncException.Kind.OTHER, "有文件正在被修改，请稍后再同步（${result.mergeStatus}）")
        }
    }

    /**
     * The files [ours] and [theirs] cannot be merged on their own, with what each side has.
     * Nothing in the repository or the working tree changes (the merge is done in memory).
     */
    private fun findConflicts(repo: Repository, ours: ObjectId, theirs: ObjectId): List<PendingConflict> {
        val merger = MergeStrategy.RECURSIVE.newMerger(repo, true) as ResolveMerger
        if (merger.merge(ours, theirs)) return emptyList()
        return merger.unmergedPaths.sorted().map { path ->
            PendingConflict(path, readAt(repo, ours.name, path), readAt(repo, theirs.name, path))
        }
    }

    /**
     * Settles every conflicted file in the half-finished merge with the side the user chose, then
     * commits it. Both sides are parents of that commit, so the side that lost is still in history.
     */
    private fun resolveConflicts(
        git: Git,
        ours: ObjectId,
        theirs: ObjectId,
        author: Author,
        device: String,
        choices: Map<String, Side>,
    ): Int {
        val repo = git.repository

        // Stage 2 = this device, stage 3 = cloud. A missing stage means that side deleted the file.
        val stages = linkedMapOf<String, Array<ObjectId?>>()
        val index = repo.readDirCache()
        for (i in 0 until index.entryCount) {
            val entry = index.getEntry(i)
            if (entry.stage > 0) stages.getOrPut(entry.pathString) { arrayOfNulls(4) }[entry.stage] = entry.objectId
        }

        for ((path, stage) in stages) {
            // findConflicts saw this merge first, so a path without a choice means the two disagree. Do not guess.
            val side = choices[path] ?: throw SyncException(SyncException.Kind.OTHER, "合并时发现新的冲突，请重新同步")
            val chosen = if (side == Side.LOCAL) stage[2] else stage[3]
            if (chosen != null) {
                writeOrDelete(path, repo.open(chosen).bytes)
                git.add().addFilepattern(path).call()
            } else {
                // The chosen side deleted the file.
                writeOrDelete(path, null)
                git.rm().addFilepattern(path).call()
            }
        }

        val ident = PersonIdent(author.name, author.email)
        git.commit()
            .setMessage(commitMessage("同步：合并云端修改（${stages.size} 个文件两边都改了，按你的选择处理）", device))
            .setAuthor(ident)
            .setCommitter(ident)
            .call()
        return stages.size
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

    /**
     * Starts a sync from a state it may build on. Another program's lock or unfinished merge is left
     * alone (design.md, product principle 5): removing them could throw away its work.
     */
    private fun prepareForSync(git: Git) {
        val repo = git.repository
        if (syncMarker().exists()) {
            recover(git)
        } else {
            val lock = File(repo.directory, "index.lock")
            val deadline = System.currentTimeMillis() + indexLockWaitMillis
            while (lock.exists()) {
                if (System.currentTimeMillis() >= deadline) {
                    throw SyncException(SyncException.Kind.OTHER, "有其他程序正在处理这个笔记本，请稍后再同步")
                }
                Thread.sleep(100)
            }
            if (repo.repositoryState != RepositoryState.SAFE) {
                throw SyncException(SyncException.Kind.OTHER, "有其他程序正在合并这个笔记本，请等它完成后再同步")
            }
        }
        syncMarker().apply {
            parentFile?.mkdirs()
            writeText("")
        }
    }

    /** Leaves the repository in a clean state after a crash in the middle of a previous sync of this app. */
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

    private fun commitPathsInternal(git: Git, paths: List<String>, author: Author, device: String, message: String?): Boolean {
        if (paths.isEmpty()) return false
        // JGit takes these as literal paths, not globs, so a note called "a[1].md" is safe.
        git.add().apply { paths.forEach(::addFilepattern) }.call()
        git.add().setUpdate(true).apply { paths.forEach(::addFilepattern) }.call()
        val staged = git.status().apply { paths.forEach(::addPath) }.call()
        val summary = message ?: describeChanges(staged.added, staged.changed, staged.removed) ?: return false
        val ident = PersonIdent(author.name, author.email)
        git.commit()
            .apply { paths.forEach(::setOnly) }
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

    private fun syncMarker() = File(workTree, ".git/$SYNC_MARKER")

    companion object {
        const val REMOTE = "origin"
        const val DEFAULT_BRANCH = "main"
        private const val TIMEOUT_SECONDS = 60
        private const val MAX_ATTEMPTS = 3

        private const val LEGACY_CONFLICT_FILE = ".git/jitnote/conflicts.json"

        /**
         * Written to `.git/jitnote/` while a sync runs. A leftover one means a sync of this app died, which is
         * the only case where a half-finished merge or an `index.lock` is ours to clean up.
         */
        internal const val SYNC_MARKER = "jitnote/syncing"

        /**
         * How long a sync waits for another program's `index.lock` to go away. Programs working on the
         * notebook hold it for well under a second per command; a variable only so tests do not have to sit it out.
         */
        @Volatile
        internal var indexLockWaitMillis = 3_000L

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

        /**
         * Gives other tools working in this notebook a name to commit with, but never replaces one the
         * user (or an earlier setup) already chose. This app's own commits name their author explicitly.
         */
        private fun applyIdentity(repo: Repository, author: Author) {
            val config = repo.config
            var changed = false
            if (config.getString("user", null, "name") == null) {
                config.setString("user", null, "name", author.name)
                changed = true
            }
            if (config.getString("user", null, "email") == null) {
                config.setString("user", null, "email", author.email)
                changed = true
            }
            if (changed) config.save()
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

        private fun blobAt(repo: Repository, commit: RevCommit, path: String): ObjectId? =
            TreeWalk.forPath(repo, path, commit.tree)?.use { it.getObjectId(0) }

        private fun touches(repo: Repository, walk: RevWalk, commit: RevCommit, path: String): Boolean {
            val mine = blobAt(repo, commit, path)
            if (commit.parentCount == 0) return mine != null
            return commit.parents.none { parent -> blobAt(repo, walk.parseCommit(parent), path) == mine }
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

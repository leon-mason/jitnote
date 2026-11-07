package io.github.leonmason.jitnote.data

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.longOrNull
import java.io.File
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.util.concurrent.atomic.AtomicInteger
import kotlin.coroutines.coroutineContext

/**
 * Finds a newer version of this app from the latest.json that each release carries on GitHub and on Gitee,
 * and downloads its APK. Both requests are anonymous: no token, no device identifier, nothing about the
 * user's notes. Not responsible for installing; the UI hands the APK to the system installer.
 */
class AppUpdates(
    private val cacheDir: File,
    private val store: StateStore,
    val currentVersion: String,
) {
    /** [apkUrls] are tried in order: Gitee first, GitHub as the fallback (design.md「检查更新」). */
    data class Release(
        val version: String,
        val notes: String,
        val apkUrls: List<String>,
        val apkSize: Long,
        val apkSha256: String,
    )

    sealed interface State {
        data object Idle : State

        /** Only for a check the user started; the check on launch stays silent. */
        data object Checking : State
        data object UpToDate : State
        data class Available(val release: Release) : State
        data class Downloading(val release: Release, val downloaded: Long) : State
        data class Downloaded(val release: Release, val apk: File) : State

        /** [release] is set when the download failed, so it can be retried. */
        data class Failed(val message: String, val release: Release?) : State
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var job: Job? = null
    private val _state = MutableStateFlow<State>(State.Idle)
    val state: StateFlow<State> = _state.asStateFlow()

    /** Checks at most once a day and says nothing unless there is a new version. */
    fun checkOnLaunch() {
        val last = store.state.value.lastUpdateCheckAt ?: 0L
        if (System.currentTimeMillis() - last < CHECK_INTERVAL_MS || job?.isActive == true) return
        job = scope.launch {
            val release = runCatching { latestRelease() }.getOrElse { return@launch }
            store.update { it.copy(lastUpdateCheckAt = System.currentTimeMillis()) }
            if (release != null && _state.value == State.Idle) _state.value = State.Available(release)
        }
    }

    fun checkNow() {
        job?.cancel()
        _state.value = State.Checking
        job = scope.launch {
            _state.value = try {
                val release = latestRelease()
                store.update { it.copy(lastUpdateCheckAt = System.currentTimeMillis()) }
                if (release != null) State.Available(release) else State.UpToDate
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                State.Failed("检查更新没有成功，请检查网络后再试。", null)
            }
        }
    }

    fun download(release: Release) {
        job?.cancel()
        _state.value = State.Downloading(release, 0)
        job = scope.launch {
            _state.value = try {
                State.Downloaded(release, fetchApk(release))
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                State.Failed("下载没有完成，可能是网络不稳定。", release)
            }
        }
    }

    /** Closes whatever is showing; also stops a check or download in progress. */
    fun dismiss() {
        job?.cancel()
        _state.value = State.Idle
    }

    /**
     * The newest version if it is newer than this app, else null. Asks GitHub and Gitee at once and takes
     * whichever answers first, so users who cannot reach GitHub do not wait for it to time out.
     * The requests run in [scope], not in the caller's job: the slower one is left to finish, because each
     * download of latest.json on GitHub is what estimates daily users (design.md「检查更新」).
     */
    private suspend fun latestRelease(): Release? {
        val release = firstSuccess(scope, MANIFEST_URLS.map { url -> { parseManifest(fetchText(url), PLATFORM) } })
        return release?.takeIf { isNewer(it.version, currentVersion) }
    }

    private fun fetchText(url: String): String {
        // Both sites redirect to their file hosts; HttpURLConnection follows https → https.
        val conn = URL(url).openConnection() as HttpURLConnection
        try {
            conn.connectTimeout = 20_000
            conn.readTimeout = 30_000
            conn.setRequestProperty("User-Agent", USER_AGENT)
            if (conn.responseCode !in 200..299) throw IOException("$url returned ${conn.responseCode}")
            return conn.inputStream.bufferedReader().use { it.readText() }
        } finally {
            conn.disconnect()
        }
    }

    private suspend fun fetchApk(release: Release): File {
        val dir = File(cacheDir, "updates")
        dir.deleteRecursively()
        dir.mkdirs()
        val apk = File(dir, "jitnote-${release.version}.apk")
        val part = File(dir, apk.name + ".part")
        downloadVerified(release.apkUrls, part, release.apkSize, release.apkSha256) { url, file ->
            _state.value = State.Downloading(release, 0)
            fetchFile(url, file) { total -> _state.value = State.Downloading(release, total) }
        }
        if (!part.renameTo(apk)) throw IOException("Could not save the download")
        return apk
    }

    private suspend fun fetchFile(url: String, file: File, progress: (Long) -> Unit) {
        val conn = URL(url).openConnection() as HttpURLConnection
        try {
            conn.connectTimeout = 20_000
            conn.readTimeout = 60_000
            conn.setRequestProperty("User-Agent", USER_AGENT)
            if (conn.responseCode !in 200..299) throw IOException("Download returned ${conn.responseCode}")
            conn.inputStream.use { input ->
                file.outputStream().use { output ->
                    val buffer = ByteArray(64 * 1024)
                    var total = 0L
                    var lastShown = 0L
                    while (true) {
                        coroutineContext.ensureActive()
                        val n = input.read(buffer)
                        if (n < 0) break
                        output.write(buffer, 0, n)
                        total += n
                        if (total - lastShown >= 256 * 1024) {
                            lastShown = total
                            progress(total)
                        }
                    }
                }
            }
        } finally {
            conn.disconnect()
        }
    }

    companion object {
        const val REPO = "leon-mason/jitnote"
        private const val USER_AGENT = "Jitnote-Android"
        private const val CHECK_INTERVAL_MS = 24 * 60 * 60 * 1000L
        private const val PLATFORM = "android"

        /**
         * Fixed addresses of the newest release's latest.json. scripts/release.sh uploads it last, after every
         * package is on both sites. Gitee has no draft releases and counts the release edited last as the
         * newest, which is why the release script never edits an older one.
         */
        internal val MANIFEST_URLS = listOf(
            "https://gitee.com/shitoupapa/jitnote/releases/download/latest/latest.json",
            "https://github.com/$REPO/releases/latest/download/latest.json",
        )

        /**
         * Reads latest.json as written by scripts/release.sh. Throws when the file is unreadable, so the
         * other site's answer can be used instead; null when it lists no usable package for [platform].
         */
        internal fun parseManifest(text: String, platform: String): Release? {
            val json = runCatching { Json.parseToJsonElement(text) as? JsonObject }.getOrNull()
                ?: throw IOException("Unreadable latest.json")
            val version = json.string("version")?.removePrefix("v") ?: throw IOException("latest.json has no version")
            val pkg = (json["packages"] as? JsonObject)?.get(platform) as? JsonObject ?: return null
            val urls = listOfNotNull(pkg.string("gitee"), pkg.string("github")).filter { it.startsWith("https://") }
            val size = (pkg["size"] as? JsonPrimitive)?.longOrNull ?: return null
            val sha256 = pkg.string("sha256")?.lowercase()?.takeIf { SHA256.matches(it) } ?: return null
            if (urls.isEmpty()) return null
            return Release(
                version = version,
                notes = json.string("notes").orEmpty().replace("\r\n", "\n").trim(),
                apkUrls = urls,
                apkSize = size,
                apkSha256 = sha256,
            )
        }

        private val SHA256 = Regex("[0-9a-f]{64}")

        /**
         * Runs every attempt in [scope] and returns the first result; throws only when all of them failed.
         * The others are not cancelled.
         */
        internal suspend fun <T> firstSuccess(scope: CoroutineScope, attempts: List<suspend () -> T>): T {
            val winner = CompletableDeferred<T>()
            val failed = AtomicInteger()
            for (attempt in attempts) {
                scope.launch {
                    try {
                        winner.complete(attempt())
                    } catch (e: Throwable) {
                        if (failed.incrementAndGet() == attempts.size) winner.completeExceptionally(e)
                        if (e is CancellationException) throw e
                    }
                }
            }
            return winner.await()
        }

        /**
         * Downloads into [file] from each URL in turn until one gives exactly [size] bytes with the expected
         * SHA-256. A package that does not match is never kept, so it can never be installed.
         */
        internal suspend fun downloadVerified(
            urls: List<String>,
            file: File,
            size: Long,
            sha256: String,
            fetch: suspend (String, File) -> Unit,
        ) {
            var last: Exception = IOException("No download address")
            for (url in urls) {
                try {
                    fetch(url, file)
                    if (file.length() == size && sha256Of(file) == sha256) return
                    last = IOException("$url gave a different file")
                } catch (e: CancellationException) {
                    file.delete()
                    throw e
                } catch (e: Exception) {
                    last = e
                }
                file.delete()
            }
            throw last
        }

        internal fun sha256Of(file: File): String {
            val digest = MessageDigest.getInstance("SHA-256")
            file.inputStream().use { input ->
                val buffer = ByteArray(64 * 1024)
                while (true) {
                    val n = input.read(buffer)
                    if (n < 0) break
                    digest.update(buffer, 0, n)
                }
            }
            return digest.digest().joinToString("") { "%02x".format(it) }
        }

        /** Compares dotted version numbers, ignoring a leading "v"; unreadable versions are never newer. */
        internal fun isNewer(candidate: String, current: String): Boolean {
            val a = parts(candidate) ?: return false
            val b = parts(current) ?: return false
            for (i in 0 until maxOf(a.size, b.size)) {
                val diff = a.getOrElse(i) { 0 } - b.getOrElse(i) { 0 }
                if (diff != 0) return diff > 0
            }
            return false
        }

        private fun parts(version: String): List<Int>? =
            version.removePrefix("v").substringBefore('-').split('.').map { it.toIntOrNull() ?: return null }

        private fun JsonObject.string(key: String): String? =
            (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull
    }
}

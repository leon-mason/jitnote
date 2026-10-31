package io.github.leonmason.gitnotebook.data

import kotlinx.coroutines.CancellationException
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
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.longOrNull
import java.io.File
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import kotlin.coroutines.coroutineContext

/**
 * Finds a newer published release of this app on GitHub and downloads its APK.
 * Talks to GitHub anonymously: no token and nothing about the user's notes is sent.
 */
class AppUpdates(
    private val cacheDir: File,
    private val store: StateStore,
    val currentVersion: String,
) {
    data class Release(val version: String, val notes: String, val apkUrl: String, val apkSize: Long)

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
                State.Failed("连不上 GitHub，请检查网络后再试。", null)
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

    /** The newest public release if it is newer than this app, else null. */
    private fun latestRelease(): Release? {
        val conn = URL("https://api.github.com/repos/$REPO/releases/latest").openConnection() as HttpURLConnection
        try {
            conn.connectTimeout = 20_000
            conn.readTimeout = 30_000
            conn.setRequestProperty("User-Agent", "Jitnote-Android")
            conn.setRequestProperty("Accept", "application/vnd.github+json")
            conn.setRequestProperty("X-GitHub-Api-Version", "2022-11-28")
            val code = conn.responseCode
            // No release published yet.
            if (code == 404) return null
            if (code !in 200..299) throw IOException("GitHub returned $code")
            val text = conn.inputStream.bufferedReader().use { it.readText() }
            val json = runCatching { Json.parseToJsonElement(text) as JsonObject }.getOrNull()
                ?: throw IOException("Unreadable release")
            return parseRelease(json)?.takeIf { isNewer(it.version, currentVersion) }
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
        // GitHub redirects the download to its file host; HttpURLConnection follows https → https.
        val conn = URL(release.apkUrl).openConnection() as HttpURLConnection
        try {
            conn.connectTimeout = 20_000
            conn.readTimeout = 60_000
            conn.setRequestProperty("User-Agent", "Jitnote-Android")
            if (conn.responseCode !in 200..299) throw IOException("Download returned ${conn.responseCode}")
            conn.inputStream.use { input ->
                part.outputStream().use { output ->
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
                            _state.value = State.Downloading(release, total)
                        }
                    }
                }
            }
        } catch (e: Exception) {
            part.delete()
            throw e
        } finally {
            conn.disconnect()
        }
        if (release.apkSize > 0 && part.length() != release.apkSize) {
            part.delete()
            throw IOException("Incomplete download")
        }
        if (!part.renameTo(apk)) throw IOException("Could not save the download")
        return apk
    }

    companion object {
        const val REPO = "leon-mason/jitnote"
        private const val CHECK_INTERVAL_MS = 24 * 60 * 60 * 1000L

        /** Reads a GitHub release; null when it has no APK or is a draft or pre-release. */
        internal fun parseRelease(release: JsonObject): Release? {
            if (release.boolean("draft") == true || release.boolean("prerelease") == true) return null
            val version = release.string("tag_name")?.removePrefix("v") ?: return null
            val apk = (release["assets"] as? JsonArray).orEmpty()
                .filterIsInstance<JsonObject>()
                .firstOrNull { it.string("name")?.endsWith(".apk") == true }
                ?: return null
            return Release(
                version = version,
                notes = release.string("body").orEmpty().replace("\r\n", "\n").trim(),
                apkUrl = apk.string("browser_download_url") ?: return null,
                apkSize = (apk["size"] as? JsonPrimitive)?.longOrNull ?: 0L,
            )
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

        private fun JsonObject.boolean(key: String): Boolean? = (this[key] as? JsonPrimitive)?.booleanOrNull
    }
}

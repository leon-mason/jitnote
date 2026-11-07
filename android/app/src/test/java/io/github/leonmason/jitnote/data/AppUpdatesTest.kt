package io.github.leonmason.jitnote.data

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.io.IOException

class AppUpdatesTest {
    @Test
    fun comparesVersionsNumerically() {
        assertTrue(AppUpdates.isNewer("v0.2.0", "0.1.0"))
        assertTrue(AppUpdates.isNewer("0.10.0", "0.9.3"))
        assertTrue(AppUpdates.isNewer("1.0", "0.9.9"))
        assertTrue(AppUpdates.isNewer("0.1.1", "0.1"))
        assertFalse(AppUpdates.isNewer("v0.1.0", "0.1.0"))
        assertFalse(AppUpdates.isNewer("0.1", "0.1.0"))
        assertFalse(AppUpdates.isNewer("0.0.9", "0.1.0"))
        assertFalse(AppUpdates.isNewer("not-a-version", "0.1.0"))
    }

    @Test
    fun readsTheApkFromLatestJson() {
        val release = AppUpdates.parseManifest(MANIFEST, "android")!!
        assertEquals("0.11.0", release.version)
        assertEquals("· 插入图片\n· 修复同步偶尔失败", release.notes)
        // Gitee first: it is the fast one for most users; GitHub is the fallback.
        assertEquals(
            listOf(
                "https://gitee.com/shitoupapa/jitnote/releases/download/v0.11.0/jitnote-0.11.0.apk",
                "https://github.com/leon-mason/jitnote/releases/download/v0.11.0/jitnote-0.11.0.apk",
            ),
            release.apkUrls,
        )
        assertEquals(2557137L, release.apkSize)
        assertEquals(SHA_OF_HELLO, release.apkSha256)
    }

    @Test
    fun rejectsUnreadableLatestJsonAndIgnoresIncompletePackages() {
        assertThrows(IOException::class.java) { AppUpdates.parseManifest("<html>Not Found</html>", "android") }
        assertThrows(IOException::class.java) { AppUpdates.parseManifest("""{"packages": {}}""", "android") }
        assertNull(AppUpdates.parseManifest("""{"version": "0.11.0", "packages": {}}""", "android"))
        assertNull(AppUpdates.parseManifest(MANIFEST, "ios"))
        val noChecksum = MANIFEST.replace(SHA_OF_HELLO, "not-a-checksum")
        assertNull(AppUpdates.parseManifest(noChecksum, "android"))
    }

    @Test
    fun takesTheFirstAnswerWithoutCancellingTheOther() = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val slowFinished = CompletableDeferred<Unit>()
        val result = AppUpdates.firstSuccess(
            scope,
            listOf(
                { throw IOException("Gitee unreachable") },
                { delay(50); "github" },
                { delay(300); slowFinished.complete(Unit); "slow" },
            ),
        )
        assertEquals("github", result)
        // The slow request still runs to the end: GitHub counts it as a download.
        withTimeout(5_000) { slowFinished.await() }
    }

    @Test
    fun failsOnlyWhenEverySiteFailed() {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        assertThrows(IOException::class.java) {
            runBlocking {
                AppUpdates.firstSuccess<String>(
                    scope,
                    listOf({ throw IOException("a") }, { delay(20); throw IOException("b") }),
                )
            }
        }
    }

    @Test
    fun keepsOnlyADownloadWithTheRightChecksum() = runBlocking {
        val file = File.createTempFile("update", ".apk")
        val tried = mutableListOf<String>()
        // Gitee hands out a different file, GitHub the right one: GitHub's is kept.
        AppUpdates.downloadVerified(listOf("gitee", "github"), file, 5, SHA_OF_HELLO) { url, target ->
            tried += url
            target.writeText(if (url == "gitee") "HELLO" else "hello")
        }
        assertEquals(listOf("gitee", "github"), tried)
        assertEquals("hello", file.readText())

        // Gitee fails outright: GitHub is tried next.
        tried.clear()
        AppUpdates.downloadVerified(listOf("gitee", "github"), file, 5, SHA_OF_HELLO) { url, target ->
            tried += url
            if (url == "gitee") throw IOException("unreachable")
            target.writeText("hello")
        }
        assertEquals(listOf("gitee", "github"), tried)

        // Nothing matches: no file is left behind to install.
        assertThrows(IOException::class.java) {
            runBlocking {
                AppUpdates.downloadVerified(listOf("gitee", "github"), file, 5, SHA_OF_HELLO) { _, target ->
                    target.writeText("HELLO")
                }
            }
        }
        assertFalse(file.exists())
    }

    private companion object {
        /** SHA-256 of the five bytes "hello". */
        const val SHA_OF_HELLO = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"

        val MANIFEST = """
            {
              "format": 1, "version": "0.11.0", "notes": "· 插入图片\r\n· 修复同步偶尔失败\n",
              "packages": {
                "android": {
                  "name": "jitnote-0.11.0.apk", "size": 2557137, "sha256": "$SHA_OF_HELLO",
                  "gitee": "https://gitee.com/shitoupapa/jitnote/releases/download/v0.11.0/jitnote-0.11.0.apk",
                  "github": "https://github.com/leon-mason/jitnote/releases/download/v0.11.0/jitnote-0.11.0.apk"
                },
                "windows-x64": {
                  "name": "Jitnote-windows-x64-0.11.0.exe", "size": 97911742, "sha256": "$SHA_OF_HELLO",
                  "gitee": "https://gitee.com/x.exe", "github": "https://github.com/x.exe"
                }
              }
            }
        """.trimIndent()
    }
}

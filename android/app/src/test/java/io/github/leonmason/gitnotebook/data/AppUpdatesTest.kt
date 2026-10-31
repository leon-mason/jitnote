package io.github.leonmason.gitnotebook.data

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AppUpdatesTest {
    private fun parse(json: String) = AppUpdates.parseRelease(Json.parseToJsonElement(json).jsonObject)

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
    fun readsTheApkFromARelease() {
        val release = parse(
            """
            {
              "tag_name": "v0.2.0", "draft": false, "prerelease": false,
              "body": "· 插入图片\r\n· 修复同步偶尔失败\r\n",
              "assets": [
                {"name": "checksums.txt", "size": 120, "browser_download_url": "https://example.com/checksums.txt"},
                {"name": "git-notebook-0.2.0.apk", "size": 12582912,
                 "browser_download_url": "https://github.com/leon-mason/git-notebook/releases/download/v0.2.0/git-notebook-0.2.0.apk"}
              ]
            }
            """,
        )!!
        assertEquals("0.2.0", release.version)
        assertEquals("· 插入图片\n· 修复同步偶尔失败", release.notes)
        assertEquals("https://github.com/leon-mason/git-notebook/releases/download/v0.2.0/git-notebook-0.2.0.apk", release.apkUrl)
        assertEquals(12582912L, release.apkSize)
    }

    @Test
    fun ignoresReleasesWithoutAnApkOrNotYetPublic() {
        assertNull(parse("""{"tag_name": "v0.2.0", "body": null, "assets": []}"""))
        val apk = """[{"name": "a.apk", "size": 1, "browser_download_url": "https://example.com/a.apk"}]"""
        assertNull(parse("""{"tag_name": "v0.2.0", "prerelease": true, "assets": $apk}"""))
        assertNull(parse("""{"tag_name": "v0.2.0", "draft": true, "assets": $apk}"""))
        assertEquals("", parse("""{"tag_name": "v0.2.0", "body": null, "assets": $apk}""")!!.notes)
    }
}

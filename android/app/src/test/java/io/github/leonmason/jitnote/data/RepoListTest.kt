package io.github.leonmason.jitnote.data

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RepoListTest {
    private fun parse(json: String) = HostingApi.parseRepos(Json.parseToJsonElement(json).jsonArray)

    @Test
    fun readsGiteeRepositories() {
        val repos = parse(
            """
            [{
              "id": 1, "full_name": "zhl/notes", "human_name": "zhl/我的笔记",
              "namespace": {"type": "personal", "name": "zhl", "path": "zhl"},
              "path": "notes", "name": "我的笔记", "owner": {"login": "zhl"},
              "description": "", "private": true, "public": false,
              "html_url": "https://gitee.com/zhl/notes.git",
              "pushed_at": "2026-10-28T10:00:00+08:00", "updated_at": "2026-10-29T10:00:00+08:00"
            }, {
              "path": "jitnote-ab12", "name": "jitnote-ab12", "owner": {"login": "zhl"},
              "description": "[Jitnote] 读书笔记", "private": true,
              "html_url": "https://gitee.com/zhl/jitnote-ab12.git"
            }]
            """,
        )
        val notes = repos[0]
        assertEquals("notes", notes.path)
        assertEquals("我的笔记", notes.displayName)
        assertEquals("https://gitee.com/zhl/notes.git", notes.cloneUrl)
        assertFalse(notes.isNotebook)
        assertTrue(notes.isPrivate)
        assertEquals("zhl", notes.owner)
        assertEquals(java.time.OffsetDateTime.parse("2026-10-28T10:00:00+08:00").toInstant().toEpochMilli(), notes.updatedAt)

        assertTrue(repos[1].isNotebook)
        assertEquals("读书笔记", repos[1].displayName)
        assertNull(repos[1].updatedAt)
    }

    @Test
    fun readsGitHubRepositories() {
        val repo = parse(
            """
            [{
              "name": "notes", "full_name": "acme/notes", "owner": {"login": "acme"},
              "private": false, "html_url": "https://github.com/acme/notes",
              "clone_url": "https://github.com/acme/notes.git", "description": null,
              "pushed_at": "2026-10-30T01:02:03Z", "size": 204800
            }]
            """,
        ).single()
        assertEquals("notes", repo.displayName)
        assertEquals("https://github.com/acme/notes.git", repo.cloneUrl)
        assertFalse(repo.isPrivate)
        assertEquals("acme", repo.owner)
        assertEquals(204800L, repo.sizeKb)
    }

    @Test
    fun normalizesPastedAddresses() {
        assertEquals("https://gitee.com/zhl/notes.git", RepoUrls.toCloneUrl("https://gitee.com/zhl/notes"))
        assertEquals("https://gitee.com/zhl/notes.git", RepoUrls.toCloneUrl(" https://gitee.com/zhl/notes/tree/master/日记 "))
        assertEquals("https://github.com/a/b.git", RepoUrls.toCloneUrl("https://www.github.com/a/b.git/"))
        assertEquals("https://git.example.com/team/notes", RepoUrls.toCloneUrl("https://git.example.com/team/notes"))
        assertEquals("https://gitee.com/zhl", RepoUrls.toCloneUrl("https://gitee.com/zhl"))
    }
}

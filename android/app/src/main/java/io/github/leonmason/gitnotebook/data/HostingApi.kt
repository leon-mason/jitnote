package io.github.leonmason.gitnotebook.data

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.put
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL

/**
 * The few platform REST calls the app needs: who owns this token, and create a private
 * repository. Notes themselves never go through these APIs, only through Git.
 */
class HostingApi {
    data class User(val login: String, val email: String)
    data class CreatedRepo(val cloneUrl: String, val webUrl: String)

    /** A repository in the user's account; [displayName] comes from the "[GitNotebook] name" description. */
    data class RemoteRepo(val path: String, val displayName: String, val cloneUrl: String, val isNotebook: Boolean)

    open class ApiException(message: String) : IOException(message)
    class NameTakenException : ApiException("仓库名已被占用")

    fun verify(provider: Provider, token: String): User {
        val user = when (provider) {
            Provider.GITHUB -> request(provider, token, "GET", "https://api.github.com/user")
            Provider.GITEE -> request(provider, token, "GET", "https://gitee.com/api/v5/user")
            Provider.OTHER -> error("No API for other hosts")
        }
        val login = user.string("login") ?: throw ApiException("无法读取账号信息")
        val id = user.string("id")
        val email = user.string("email")?.takeIf { it.isNotBlank() } ?: when (provider) {
            Provider.GITHUB -> "$id+$login@users.noreply.github.com"
            else -> "$id+$login@user.noreply.gitee.com"
        }
        return User(login, email)
    }

    /** The user's repositories, notebooks created by this app first. */
    fun listRepos(provider: Provider, token: String): List<RemoteRepo> {
        val url = when (provider) {
            Provider.GITHUB -> "https://api.github.com/user/repos?per_page=100&sort=updated&affiliation=owner"
            Provider.GITEE -> "https://gitee.com/api/v5/user/repos?per_page=100&sort=updated&type=owner"
            Provider.OTHER -> error("No API for other hosts")
        }
        return requestElement(provider, token, "GET", url).jsonArray.mapNotNull { element ->
            val repo = element as? JsonObject ?: return@mapNotNull null
            val web = repo.string("html_url")?.removeSuffix(".git") ?: return@mapNotNull null
            val path = repo.string("path") ?: repo.string("name") ?: web.substringAfterLast('/')
            val description = repo.string("description").orEmpty()
            val marked = description.startsWith(NOTEBOOK_MARK)
            RemoteRepo(
                path = path,
                displayName = if (marked) description.removePrefix(NOTEBOOK_MARK).trim() else repo.string("human_name") ?: path,
                cloneUrl = repo.string("clone_url") ?: "$web.git",
                isNotebook = marked,
            )
        }.sortedByDescending { it.isNotebook }
    }

    fun createPrivateRepo(provider: Provider, token: String, name: String, path: String): CreatedRepo {
        val description = "$NOTEBOOK_MARK $name"
        return when (provider) {
            Provider.GITHUB -> {
                val body = buildJsonObject {
                    put("name", path)
                    put("description", description)
                    put("private", true)
                    put("auto_init", true)
                    put("has_issues", false)
                    put("has_wiki", false)
                    put("has_projects", false)
                }
                val repo = request(provider, token, "POST", "https://api.github.com/user/repos", body)
                CreatedRepo(repo.string("clone_url")!!, repo.string("html_url")!!)
            }
            Provider.GITEE -> {
                val body = buildJsonObject {
                    put("name", name)
                    put("path", path)
                    put("description", description)
                    put("private", true)
                    put("auto_init", true)
                    put("has_issues", false)
                    put("has_wiki", false)
                }
                val repo = request(provider, token, "POST", "https://gitee.com/api/v5/user/repos", body)
                val web = repo.string("html_url")!!.removeSuffix(".git")
                CreatedRepo("$web.git", web)
            }
            Provider.OTHER -> error("No API for other hosts")
        }
    }

    private fun request(provider: Provider, token: String, method: String, url: String, body: JsonObject? = null): JsonObject =
        requestElement(provider, token, method, url, body) as? JsonObject ?: throw ApiException("云端返回了无法识别的内容")

    private fun requestElement(provider: Provider, token: String, method: String, url: String, body: JsonObject? = null): JsonElement {
        val conn = URL(url).openConnection() as HttpURLConnection
        try {
            conn.requestMethod = method
            conn.connectTimeout = 20_000
            conn.readTimeout = 30_000
            conn.setRequestProperty("User-Agent", "GitNotebook-Android")
            conn.setRequestProperty("Accept", "application/json")
            when (provider) {
                Provider.GITHUB -> {
                    conn.setRequestProperty("Authorization", "Bearer $token")
                    conn.setRequestProperty("Accept", "application/vnd.github+json")
                    conn.setRequestProperty("X-GitHub-Api-Version", "2022-11-28")
                }
                else -> conn.setRequestProperty("Authorization", "token $token")
            }
            if (body != null) {
                conn.doOutput = true
                conn.setRequestProperty("Content-Type", "application/json; charset=utf-8")
                conn.outputStream.use { it.write(body.toString().toByteArray()) }
            }
            val code = conn.responseCode
            val text = (if (code in 200..299) conn.inputStream else conn.errorStream)
                ?.bufferedReader()?.use { it.readText() }.orEmpty()
            val json = runCatching { Json.parseToJsonElement(text) }.getOrNull()
            if (code in 200..299) return json ?: throw ApiException("云端返回了无法识别的内容")

            val message = (json as? JsonObject)?.string("message") ?: text.take(200)
            throw when {
                code == 401 -> ApiException("令牌不对或已过期，请重新生成后粘贴")
                code == 403 -> ApiException("令牌缺少需要的权限，请按步骤重新生成：$message")
                (code == 422 || code == 400) && message.contains("exist", true) -> NameTakenException()
                code == 422 || code == 400 -> if (message.contains("已存在")) NameTakenException() else ApiException(message)
                else -> ApiException("云端请求失败（$code）：$message")
            }
        } finally {
            conn.disconnect()
        }
    }

    private companion object {
        const val NOTEBOOK_MARK = "[GitNotebook]"
    }

    private fun JsonObject.string(key: String): String? =
        (this[key] as? JsonPrimitive)?.takeIf { it.booleanOrNull == null || it.isString }?.contentOrNull
}

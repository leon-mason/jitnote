package io.github.leonmason.jitnote.data

import java.net.URI

object RepoUrls {
    private val knownHosts = setOf("github.com", "www.github.com", "gitee.com", "www.gitee.com")

    /**
     * Turns what people paste (often the browser address, e.g. ".../tree/master/docs") into a
     * clone URL. GitHub and Gitee repositories are always owner/name; other hosts are kept as is.
     */
    fun toCloneUrl(input: String): String {
        val text = input.trim().removeSuffix("/")
        val uri = runCatching { URI(text) }.getOrNull() ?: return text
        val host = uri.host?.lowercase() ?: return text
        if (host !in knownHosts) return text
        val segments = uri.path.orEmpty().split('/').filter { it.isNotEmpty() }
        if (segments.size < 2) return text
        val name = segments[1].removeSuffix(".git")
        return "https://${host.removePrefix("www.")}/${segments[0]}/$name.git"
    }
}

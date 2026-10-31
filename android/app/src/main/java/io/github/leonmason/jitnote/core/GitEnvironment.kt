package io.github.leonmason.jitnote.core

import org.eclipse.jgit.lib.Config
import org.eclipse.jgit.storage.file.FileBasedConfig
import org.eclipse.jgit.util.FS
import org.eclipse.jgit.util.SystemReader
import java.io.File
import java.util.TimeZone

/**
 * Isolates JGit from the host environment: no system git binary, no ~/.gitconfig.
 * Android has neither, and on a developer machine (unit tests) we must not pick up the
 * developer's own config. JGit's global config files live in [configDir] instead.
 */
object GitEnvironment {
    @Volatile
    private var installed = false

    fun install(configDir: File) {
        if (installed) return
        synchronized(this) {
            if (installed) return
            configDir.mkdirs()
            SystemReader.setInstance(IsolatedSystemReader(SystemReader.getInstance(), configDir))
            installed = true
        }
    }
}

private class IsolatedSystemReader(
    private val base: SystemReader,
    private val dir: File,
) : SystemReader() {
    // The default implementation resolves the local host name over the network.
    override fun getHostname(): String = "jitnote"

    override fun getenv(variable: String): String? = null

    override fun getProperty(key: String): String? = base.getProperty(key)

    override fun openUserConfig(parent: Config?, fs: FS): FileBasedConfig =
        FileBasedConfig(parent, File(dir, "user.gitconfig"), fs)

    override fun openSystemConfig(parent: Config?, fs: FS): FileBasedConfig =
        FileBasedConfig(parent, File(dir, "system.gitconfig"), fs)

    override fun openJGitConfig(parent: Config?, fs: FS): FileBasedConfig =
        FileBasedConfig(parent, File(dir, "jgit.config"), fs)

    override fun getCurrentTime(): Long = System.currentTimeMillis()

    override fun getTimezone(time: Long): Int = TimeZone.getDefault().getOffset(time) / 60_000
}

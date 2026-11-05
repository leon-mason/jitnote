package io.github.leonmason.jitnote.data

/**
 * When「启动时自动同步」should start a sync. See design.md「同步规则」.
 * This does not start the sync; each client calls it when the app enters or leaves the foreground.
 */
object AutoSync {
    /**
     * A quick trip out (copy a line, pull down the notification shade) must not lock the open note
     * on "正在同步". A minute covers that. Coming back after writing on another device takes longer.
     */
    const val MIN_AWAY_MS = 60_000L

    /**
     * WebView may not answer `evaluateJavascript` until the activity is started again, so a save
     * requested on the way to the background can land just after we return. Wait this long before
     * an automatic sync that follows a background, so that save is on disk first. A cold start has
     * nothing pending and does not wait.
     */
    const val RESUME_FLUSH_MS = 500L

    /**
     * [awayMs] is null the first time the process comes to the foreground, and on a duplicate
     * foreground event that had no background in between. [launchHandled] is true after that first
     * event, so the duplicate does not sync again.
     */
    fun shouldStart(enabled: Boolean, busy: Boolean, hasNotebook: Boolean, awayMs: Long?, launchHandled: Boolean): Boolean {
        if (!enabled || busy || !hasNotebook) return false
        if (awayMs == null) return !launchHandled
        return awayMs >= MIN_AWAY_MS
    }
}

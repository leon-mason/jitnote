package io.github.leonmason.jitnote.data

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AutoSyncTest {
    @Test
    fun coldStartSyncsOnlyOnce() {
        assertTrue(AutoSync.shouldStart(enabled = true, busy = false, hasNotebook = true, awayMs = null, launchHandled = false))
        assertFalse(AutoSync.shouldStart(enabled = true, busy = false, hasNotebook = true, awayMs = null, launchHandled = true))
    }

    @Test
    fun aShortTripToTheBackgroundDoesNotSync() {
        assertFalse(AutoSync.shouldStart(true, false, true, AutoSync.MIN_AWAY_MS - 1, true))
        assertTrue(AutoSync.shouldStart(true, false, true, AutoSync.MIN_AWAY_MS, true))
    }

    @Test
    fun staysOffWhenDisabledBusyOrThereIsNoNotebook() {
        assertFalse(AutoSync.shouldStart(false, false, true, null, false))
        assertFalse(AutoSync.shouldStart(true, true, true, null, false))
        assertFalse(AutoSync.shouldStart(true, false, false, null, false))
    }
}

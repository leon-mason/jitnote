package io.github.leonmason.jitnote.data

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.File

/** The app's own small state (keys and notebook list), kept as one JSON file. */
class StateStore(private val file: File) {
    private val json = Json {
        ignoreUnknownKeys = true
        prettyPrint = true
    }
    private val _state = MutableStateFlow(load())
    val state: StateFlow<AppState> = _state.asStateFlow()

    @Synchronized
    fun update(transform: (AppState) -> AppState) {
        val next = transform(_state.value)
        file.parentFile?.mkdirs()
        val tmp = File(file.path + ".tmp")
        tmp.writeText(json.encodeToString(next))
        if (!tmp.renameTo(file)) {
            file.writeText(tmp.readText())
            tmp.delete()
        }
        _state.value = next
    }

    private fun load(): AppState =
        if (file.exists()) runCatching { json.decodeFromString<AppState>(file.readText()) }.getOrDefault(AppState())
        else AppState()
}

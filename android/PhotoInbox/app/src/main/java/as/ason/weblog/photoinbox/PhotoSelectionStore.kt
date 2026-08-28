package com.asonas.weblog.photoinbox

import android.content.Context

enum class PhotoSelectionStatus { SELECTED, EXCLUDED, UPLOADED }

class PhotoSelectionStore(context: Context) {
    private val preferences = context.getSharedPreferences("photo-selection", Context.MODE_PRIVATE)
    private val excluded = mutableSetOf<String>()
    private val uploaded = mutableSetOf<String>()
    private val selected = mutableSetOf<String>()

    fun updatePhotos(photos: List<LibraryPhoto>) {
        reloadPersistedState()
        selected.clear()
        selected += photos.map { it.uri.toString() }.filterNot { it in excluded || it in uploaded }
    }

    fun toggle(uri: String) {
        if (uri in uploaded) return
        if (!selected.remove(uri)) {
            selected += uri
            excluded -= uri
        } else {
            excluded += uri
        }
        persist()
    }

    fun markUploaded(uri: String) {
        uploaded += uri
        selected -= uri
        excluded -= uri
        persist()
    }

    fun selectedUris(): Set<String> = selected.toSet()

    fun status(uri: String): PhotoSelectionStatus = when (uri) {
        in uploaded -> PhotoSelectionStatus.UPLOADED
        in selected -> PhotoSelectionStatus.SELECTED
        else -> PhotoSelectionStatus.EXCLUDED
    }

    private fun persist() {
        preferences.edit().putStringSet("excluded", excluded).putStringSet("uploaded", uploaded).apply()
    }

    private fun reloadPersistedState() {
        excluded.clear()
        excluded += preferences.getStringSet("excluded", emptySet()).orEmpty()
        uploaded.clear()
        uploaded += preferences.getStringSet("uploaded", emptySet()).orEmpty()
    }
}

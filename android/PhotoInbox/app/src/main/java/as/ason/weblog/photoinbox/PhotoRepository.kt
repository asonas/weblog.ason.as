package com.asonas.weblog.photoinbox

import android.content.ContentUris
import android.content.Context
import android.net.Uri
import android.provider.MediaStore
import java.time.Instant
import java.time.ZoneId

data class LibraryPhoto(
    val uri: Uri,
    val capturedAt: Instant,
    val capturedAtSource: String,
)

class PhotoRepository(private val context: Context) {
    fun loadToday(now: Instant = Instant.now(), zone: ZoneId = ZoneId.systemDefault()): List<LibraryPhoto> {
        val today = now.atZone(zone).toLocalDate()
        val start = today.atStartOfDay(zone).toInstant().toEpochMilli()
        val end = today.plusDays(1).atStartOfDay(zone).toInstant().toEpochMilli()
        val collection = MediaStore.Images.Media.EXTERNAL_CONTENT_URI
        val projection = arrayOf(
            MediaStore.Images.Media._ID,
            MediaStore.Images.Media.DATE_TAKEN,
            MediaStore.Images.Media.DATE_ADDED,
        )
        val taken = MediaStore.Images.Media.DATE_TAKEN
        val added = MediaStore.Images.Media.DATE_ADDED
        val selection = "($taken >= ? AND $taken < ?) OR (($taken IS NULL OR $taken = 0) AND $added >= ? AND $added < ?)"
        val arguments = arrayOf(
            start.toString(),
            end.toString(),
            (start / 1000).toString(),
            (end / 1000).toString(),
        )
        return context.contentResolver.query(
            collection,
            projection,
            selection,
            arguments,
            "${MediaStore.Images.Media.DATE_TAKEN} DESC",
        )?.use { cursor ->
            val idIndex = cursor.getColumnIndexOrThrow(MediaStore.Images.Media._ID)
            val takenIndex = cursor.getColumnIndexOrThrow(MediaStore.Images.Media.DATE_TAKEN)
            val addedIndex = cursor.getColumnIndexOrThrow(MediaStore.Images.Media.DATE_ADDED)
            buildList {
                while (cursor.moveToNext()) {
                    val taken = cursor.getLong(takenIndex)
                    val added = cursor.getLong(addedIndex) * 1000
                    add(
                        LibraryPhoto(
                            uri = ContentUris.withAppendedId(collection, cursor.getLong(idIndex)),
                            capturedAt = Instant.ofEpochMilli(if (taken > 0) taken else added),
                            capturedAtSource = if (taken > 0) "photos" else "uploaded",
                        ),
                    )
                }
            }
        }.orEmpty()
    }
}

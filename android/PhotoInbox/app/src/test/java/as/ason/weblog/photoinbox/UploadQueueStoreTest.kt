package com.asonas.weblog.photoinbox

import java.io.File
import java.time.Instant
import java.util.UUID
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class UploadQueueStoreTest {
    @get:Rule
    val temporaryFolder = TemporaryFolder()

    @Test
    fun `queue survives reopening and rejects the same photo twice`() = runTest {
        val file = File(temporaryFolder.root, "queue.json")
        val original = item("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", "content://media/1")
        UploadQueueStore(file).enqueue(listOf(original, item("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb", "content://media/1")))

        val restored = UploadQueueStore(file).items()

        assertEquals(listOf(original), restored)
    }

    @Test
    fun `stage update and removal use stable client upload id`() = runTest {
        val file = File(temporaryFolder.root, "queue.json")
        val id = "cccccccc-cccc-cccc-cccc-cccccccccccc"
        val store = UploadQueueStore(file)
        store.enqueue(listOf(item(id, "content://media/2")))

        store.updateStage(UUID.fromString(id), UploadStage.UPLOADING, "server-upload-id")

        assertEquals(UploadStage.UPLOADING, store.items().single().stage)
        assertEquals("server-upload-id", store.items().single().uploadId)
        store.remove(UUID.fromString(id))
        assertTrue(store.items().isEmpty())
    }

    private fun item(id: String, uri: String) = UploadItem(
        clientUploadId = UUID.fromString(id),
        assetUri = uri,
        capturedAt = Instant.parse("2026-08-28T01:02:03Z"),
        capturedAtSource = "photos",
    )
}

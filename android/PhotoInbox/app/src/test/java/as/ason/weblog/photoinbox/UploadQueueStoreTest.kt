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

    @Test
    fun `invalid prepared data remains stopped until manual retry regenerates it`() = runTest {
        val file = File(temporaryFolder.root, "queue.json")
        val prepared = temporaryFolder.newFile("prepared.jpg").apply { writeText("invalid") }
        val original = item("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", "content://media/1").copy(
            preparedFilePath = prepared.path, contentType = "image/jpeg", size = 7, sha256 = "wrong", width = 640, height = 480,
        )
        val store = UploadQueueStore(file)
        store.enqueue(listOf(original))
        store.updateFailure(original.clientUploadId, UploadFailure("不正なデータ", false, "invalid_sha256", requestId = "req-123"))
        val reopened = UploadQueueStore(file)
        val failed = reopened.items().single()
        assertEquals(false, failed.shouldAttemptAutomatically)
        assertEquals("req-123", failed.failure?.requestId)
        assertEquals(640, failed.width)
        reopened.retry(original.clientUploadId)
        val retry = reopened.items().single()
        assertTrue(retry.shouldAttemptAutomatically)
        assertTrue(retry.clientUploadId != original.clientUploadId)
        assertEquals(UploadStage.PENDING, retry.stage)
        assertEquals(null, retry.preparedFilePath)
        assertEquals(null, retry.sha256)
        assertEquals(null, retry.size)
        assertEquals(null, retry.width)
        assertEquals(null, retry.height)
        assertEquals(false, prepared.exists())
    }

    @Test
    fun `network retry preserves prepared data and upload identity`() = runTest {
        val store = UploadQueueStore(File(temporaryFolder.root, "queue.json"))
        val original = item("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", "content://media/1").copy(preparedFilePath = "prepared.jpg", sha256 = "sha")
        store.enqueue(listOf(original))
        store.updateFailure(original.clientUploadId, UploadFailure("offline", true))
        assertTrue(store.items().single().shouldAttemptAutomatically)
        store.retry(original.clientUploadId)
        assertEquals(original, store.items().single())
    }

    @Test
    fun `screen and worker stores see each other's changes without losing queued photos`() = runTest {
        val file = File(temporaryFolder.root, "queue.json")
        val screen = UploadQueueStore(file)
        val worker = UploadQueueStore(file)
        assertTrue(screen.items().isEmpty())
        val first = item("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", "content://media/1")
        val second = item("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb", "content://media/2")
        worker.enqueue(listOf(first))
        screen.enqueue(listOf(second))
        worker.updateFailure(first.clientUploadId, UploadFailure("拒否", false))
        assertEquals(listOf(first.assetUri, second.assetUri), screen.items().map { it.assetUri })
        assertEquals("拒否", screen.items().first().failure?.message)
    }
}

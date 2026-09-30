package com.asonas.weblog.photoinbox

import java.io.File
import kotlinx.coroutines.test.runTest
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.SocketPolicy
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject

@RunWith(RobolectricTestRunner::class)
class MemoStoreTest {
    @Test
    fun unsentEditsSurviveRestartAndStaleEditorsKeepBothVersions() = runTest {
        val directory = java.nio.file.Files.createTempDirectory("inbox-memos").toFile()
        try {
            val file = File(directory, "memos.json")
            val store = MemoStore(file)
            val id = store.add("元の本文")
            store.edit(id, "先の編集", "元の本文")
            val copy = store.edit(id, "別の編集", "元の本文")
            assertNotEquals(id, copy)
            assertEquals(setOf("先の編集", "別の編集"), MemoStore(file).memos.value.map { it.body }.toSet())
        } finally { directory.deleteRecursively() }
    }

    @Test
    fun lostResponseRetriesTheSameOperationAfterRestart() = runTest {
        val directory = java.nio.file.Files.createTempDirectory("inbox-memos").toFile()
        val server = MockWebServer()
        server.start(java.net.InetAddress.getByName("127.0.0.1"), 0)
        try {
            val api = MobileApiClient(server.url("/").newBuilder().host("127.0.0.1").build(), "paired", okhttp3.OkHttpClient.Builder().retryOnConnectionFailure(false).build())
            val file = File(directory, "memos.json")
            val store = MemoStore(file)
            val key = store.add("保存する本文")
            server.enqueue(MockResponse().setSocketPolicy(SocketPolicy.DISCONNECT_AFTER_REQUEST))
            try { store.sync(api); fail("Expected a lost response") } catch (_: java.io.IOException) { }
            val original = server.takeRequest()
            val restored = MemoStore(file)
            restored.edit(key, "保存する本文に追記", "保存する本文")
            server.enqueue(MockResponse().setBody("""{"id":"conflict-copy","revision":1,"state":"available","result":"preserved_as_new"}"""))
            server.enqueue(MockResponse().setBody("""{"memos":[{"id":"conflict-copy","body":"保存する本文","revision":1,"updated_at":"2026-10-01"}]}"""))
            restored.sync(api)
            val retried = server.takeRequest()
            assertEquals("Bearer paired", retried.getHeader("Authorization"))
            assertEquals(Json.parseToJsonElement(original.body.readUtf8()).jsonObject, Json.parseToJsonElement(retried.body.readUtf8()).jsonObject)
            assertEquals("保存する本文に追記", restored.memos.value.single().body)
            assertEquals("conflict-copy", restored.memos.value.single().serverId)
            assertEquals(key, restored.memos.value.single().id)
        } finally { server.shutdown(); directory.deleteRecursively() }
    }
}

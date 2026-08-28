package com.asonas.weblog.photoinbox

import java.io.File
import java.time.Instant
import java.util.UUID
import kotlinx.coroutines.test.runTest
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class MobileApiClientTest {
    private lateinit var server: MockWebServer
    private lateinit var http: OkHttpClient

    @get:Rule
    val temporaryFolder = TemporaryFolder()

    @Before
    fun setUp() {
        server = MockWebServer()
        server.start()
        http = OkHttpClient()
    }

    @After
    fun tearDown() {
        server.shutdown()
    }

    @Test
    fun `pairing exchange uppercases code without authorization`() = runTest {
        server.enqueue(MockResponse().setBody("""{"token":"mobile-token"}"""))

        val paired = MobileApiClient(server.url("/"), null, http)
            .exchangePairing("ab12cd34ef56", "Pixel")

        val request = server.takeRequest()
        assertEquals("mobile-token", paired.token)
        assertEquals("/api/mobile/pairings/exchange", request.path)
        assertEquals(null, request.getHeader("Authorization"))
        assertEquals(
            """{"code":"AB12CD34EF56","device_name":"Pixel"}""",
            request.body.readUtf8(),
        )
    }

    @Test
    fun `create and complete upload use the mobile contract`() = runTest {
        server.enqueue(MockResponse().setBody(signedUploadJson()))
        server.enqueue(MockResponse().setResponseCode(204))
        val client = MobileApiClient(server.url("/"), "mobile-token", http)

        val signed = client.createUpload(
            CreateUploadRequest(
                clientUploadId = UUID.fromString("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"),
                contentType = "image/jpeg",
                size = 123,
                sha256 = "abc123",
                capturedAt = Instant.parse("2026-08-28T01:02:03Z"),
                capturedAtSource = "photos",
            ),
        )
        client.complete(signed.uploadId)

        val create = server.takeRequest()
        assertEquals("Bearer mobile-token", create.getHeader("Authorization"))
        assertEquals("/api/mobile/uploads", create.path)
        assertEquals(
            """{"client_upload_id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","content_type":"image/jpeg","size":123,"sha256":"abc123","captured_at":"2026-08-28T01:02:03Z","captured_at_source":"photos"}""",
            create.body.readUtf8(),
        )
        assertEquals("/api/mobile/uploads/server-id/complete", server.takeRequest().path)
    }

    @Test
    fun `signed upload posts fields and photo as multipart form`() = runTest {
        server.enqueue(MockResponse().setResponseCode(204))
        val file = temporaryFolder.newFile("photo.jpg").apply { writeText("photo-body") }

        MultipartUploader(http).upload(
            file,
            SignedUpload("server-id", server.url("/bucket"), mapOf("key" to "inbox/photo", "Content-Type" to "image/jpeg"), Instant.MAX),
        )

        val request = server.takeRequest()
        val body = request.body.readUtf8()
        assertEquals("/bucket", request.path)
        assertTrue(request.getHeader("Content-Type")!!.startsWith("multipart/form-data; boundary="))
        assertTrue(body.contains("name=\"key\"\r\n"))
        assertTrue(body.contains("inbox/photo"))
        assertTrue(body.contains("name=\"file\"; filename=\"photo\""))
        assertTrue(body.contains("photo-body"))
    }

    private fun signedUploadJson() = """
        {
          "upload_id":"server-id",
          "upload_url":"${server.url("/bucket")}",
          "fields":{"key":"inbox/photo","Content-Type":"image/jpeg"},
          "expires_at":"2026-08-28T02:02:03Z"
        }
    """.trimIndent()
}

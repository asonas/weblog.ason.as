package com.asonas.weblog.photoinbox

import java.time.Instant
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class PairingQrTest {
    private val now = Instant.parse("2026-10-03T12:00:00Z")
    private val payload = """{"type":"weblog-photo-inbox-pairing","version":1,"server":"https://weblog.ason.as","code":"ABCDEFGH2345","expires_at":"2026-10-03T12:10:00Z"}"""

    @Test
    fun `reads the web pairing payload without accepting another server or expired code`() {
        assertEquals("ABCDEFGH2345", PairingQr.code(payload, now))
        for (invalid in listOf(
            payload.replace("https://weblog.ason.as", "https://example.com"),
            payload.replace("https://", "http://"),
            payload.replace("ABCDEFGH2345", "invalid"),
            payload.replace("\"version\":1", "\"version\":2"),
            payload.replace("12:10:00Z", "12:00:00Z"),
            "https://example.com/",
        )) {
            assertThrows(RuntimeException::class.java) { PairingQr.code(invalid, now) }
        }
    }
}

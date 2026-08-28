package com.asonas.weblog.photoinbox

import android.graphics.Bitmap
import android.graphics.Color
import android.net.Uri
import androidx.test.core.app.ApplicationProvider
import java.io.File
import java.security.MessageDigest
import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

@RunWith(RobolectricTestRunner::class)
class ImagePreparerTest {
    @get:Rule
    val temporaryFolder = TemporaryFolder()

    @Test
    fun `opaque image becomes jpeg with matching metadata`() {
        val source = imageFile("source.png", hasAlpha = false)

        val prepared = ImagePreparer(ApplicationProvider.getApplicationContext()).prepare(
            Uri.fromFile(source),
            temporaryFolder.newFolder("prepared"),
            UUID.fromString("11111111-1111-1111-1111-111111111111"),
        )

        assertEquals("image/jpeg", prepared.contentType)
        assertEquals("11111111-1111-1111-1111-111111111111.jpg", prepared.file.name)
        assertEquals(prepared.file.length(), prepared.size)
        assertEquals(sha256(prepared.file), prepared.sha256)
    }

    @Test
    fun `transparent image remains png`() {
        val source = imageFile("transparent.png", hasAlpha = true)

        val prepared = ImagePreparer(ApplicationProvider.getApplicationContext()).prepare(
            Uri.fromFile(source),
            temporaryFolder.newFolder("prepared"),
            UUID.fromString("22222222-2222-2222-2222-222222222222"),
        )

        assertEquals("image/png", prepared.contentType)
        assertEquals("22222222-2222-2222-2222-222222222222.png", prepared.file.name)
        assertTrue(Bitmap.createBitmap(1, 1, Bitmap.Config.ARGB_8888).hasAlpha())
    }

    private fun imageFile(name: String, hasAlpha: Boolean): File {
        val file = temporaryFolder.newFile(name)
        val bitmap = Bitmap.createBitmap(2, 2, Bitmap.Config.ARGB_8888)
        bitmap.eraseColor(if (hasAlpha) Color.argb(128, 0, 0, 255) else Color.BLUE)
        val format = if (hasAlpha) Bitmap.CompressFormat.PNG else Bitmap.CompressFormat.JPEG
        file.outputStream().use { bitmap.compress(format, 100, it) }
        return file
    }

    private fun sha256(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256").digest(file.readBytes())
        return digest.joinToString("") { "%02x".format(it) }
    }
}

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
import org.robolectric.annotation.GraphicsMode

@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
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
        assertEquals(2, prepared.width)
        assertEquals(2, prepared.height)
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

    @Test
    fun `oversized transparent image is resized below the limit with matching dimensions`() {
        val source = temporaryFolder.newFile("large.png")
        val bitmap = Bitmap.createBitmap(100, 100, Bitmap.Config.ARGB_8888)
        for (y in 0 until 100) for (x in 0 until 100) bitmap.setPixel(x, y, Color.argb(128, x * 2, y * 2, (x * y) % 256))
        source.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
        val preparer = ImagePreparer(ApplicationProvider.getApplicationContext())
        val full = preparer.prepare(Uri.fromFile(source), temporaryFolder.newFolder("full"), UUID.randomUUID())
        val limited = ImagePreparer(ApplicationProvider.getApplicationContext(), full.size - 1).prepare(
            Uri.fromFile(source), temporaryFolder.newFolder("limited"), UUID.randomUUID(),
        )
        assertTrue(limited.size < full.size)
        assertTrue(limited.width!! < 100)
        val result = android.graphics.BitmapFactory.decodeFile(limited.file.path)
        assertEquals(result.width, limited.width)
        assertEquals(result.height, limited.height)
        assertTrue(result.hasAlpha())
        assertEquals(sha256(limited.file), limited.sha256)
    }

    @Test
    fun `image that cannot fit is rejected without leaving an upload file`() {
        val directory = temporaryFolder.newFolder("too-small")
        try {
            ImagePreparer(ApplicationProvider.getApplicationContext(), 1).prepare(Uri.fromFile(imageFile("source.png", false)), directory, UUID.randomUUID())
            throw AssertionError("Expected size rejection")
        } catch (_: ImagePreparationException) {
            assertTrue(directory.listFiles()!!.isEmpty())
        }
    }
}

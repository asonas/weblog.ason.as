package com.asonas.weblog.photoinbox

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.net.Uri
import androidx.exifinterface.media.ExifInterface
import java.io.File
import java.security.MessageDigest
import java.util.UUID

data class PreparedPhoto(
    val file: File,
    val contentType: String,
    val size: Long,
    val sha256: String,
    val width: Int? = null,
    val height: Int? = null,
)

class ImagePreparer(private val context: Context, private val maxBytes: Long = 25L * 1024 * 1024) {
    fun prepare(source: Uri, directory: File, id: UUID): PreparedPhoto {
        val bytes = context.contentResolver.openInputStream(source)?.use { it.readBytes() }
            ?: throw ImagePreparationException("Image is unavailable")
        val bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
            ?: throw ImagePreparationException("Image conversion failed")
        val oriented = applyOrientation(bitmap, bytes)
        val hasAlpha = sourceHasAlpha(bytes, oriented)
        val extension = if (hasAlpha) "png" else "jpg"
        val contentType = if (hasAlpha) "image/png" else "image/jpeg"
        val format = if (hasAlpha) Bitmap.CompressFormat.PNG else Bitmap.CompressFormat.JPEG
        directory.mkdirs()
        val output = File(directory, "${id}.$extension")
        try {
            for (scale in listOf(1.0, 0.85, 0.7, 0.55)) {
                val image = if (scale == 1.0) oriented else Bitmap.createScaledBitmap(
                    oriented, maxOf(1, (oriented.width * scale).toInt()), maxOf(1, (oriented.height * scale).toInt()), true,
                )
                try {
                    for (quality in if (hasAlpha) listOf(100) else listOf(82, 70, 58)) {
                        if (!output.outputStream().use { image.compress(format, quality, it) }) throw ImagePreparationException("Image conversion failed")
                        if (output.length() > maxBytes) continue
                        val digest = MessageDigest.getInstance("SHA-256").digest(output.readBytes())
                        return PreparedPhoto(output, contentType, output.length(), digest.joinToString("") { "%02x".format(it) }, image.width, image.height)
                    }
                } finally {
                    if (image !== oriented) image.recycle()
                }
            }
            throw ImagePreparationException("Image exceeds upload size limit")
        } catch (error: Exception) {
            output.delete()
            throw error
        } finally {
            if (oriented !== bitmap) oriented.recycle()
            bitmap.recycle()
        }
    }

    private fun applyOrientation(bitmap: Bitmap, bytes: ByteArray): Bitmap {
        val orientation = bytes.inputStream().use {
            ExifInterface(it).getAttributeInt(
                ExifInterface.TAG_ORIENTATION,
                ExifInterface.ORIENTATION_NORMAL,
            )
        }
        val matrix = Matrix().apply {
            when (orientation) {
                ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> setScale(-1f, 1f)
                ExifInterface.ORIENTATION_ROTATE_180 -> setRotate(180f)
                ExifInterface.ORIENTATION_FLIP_VERTICAL -> setScale(1f, -1f)
                ExifInterface.ORIENTATION_TRANSPOSE -> {
                    setRotate(90f)
                    postScale(-1f, 1f)
                }
                ExifInterface.ORIENTATION_ROTATE_90 -> setRotate(90f)
                ExifInterface.ORIENTATION_TRANSVERSE -> {
                    setRotate(-90f)
                    postScale(-1f, 1f)
                }
                ExifInterface.ORIENTATION_ROTATE_270 -> setRotate(-90f)
            }
        }
        if (matrix.isIdentity) return bitmap
        return Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true)
    }

    private fun sourceHasAlpha(bytes: ByteArray, bitmap: Bitmap): Boolean {
        val pngSignature = byteArrayOf(-119, 80, 78, 71, 13, 10, 26, 10)
        if (bytes.size > 25 && bytes.copyOfRange(0, 8).contentEquals(pngSignature)) {
            return bytes[25].toInt() == 4 || bytes[25].toInt() == 6
        }
        return bitmap.hasAlpha()
    }
}

class ImagePreparationException(message: String) : Exception(message)

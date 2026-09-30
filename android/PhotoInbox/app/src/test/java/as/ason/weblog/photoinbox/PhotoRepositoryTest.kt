package com.asonas.weblog.photoinbox

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.database.sqlite.SQLiteDatabase
import android.net.Uri
import android.provider.MediaStore
import androidx.test.core.app.ApplicationProvider
import java.time.Instant
import java.time.ZoneId
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowContentResolver

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28])
class PhotoRepositoryTest {
    private lateinit var provider: TestPhotoProvider

    @Before
    fun setUp() {
        provider = TestPhotoProvider()
        provider.onCreate()
        ShadowContentResolver.registerProviderInternal("media", provider)
    }

    @After
    fun tearDown() { provider.database.close() }

    @Test
    fun `recent photos include today and six preceding calendar days with added-date fallback`() {
        provider.add(1, "2026-09-23T14:59:59Z")
        provider.add(2, "2026-09-23T15:00:00Z")
        provider.add(3, "2026-09-30T14:59:59Z")
        provider.add(4, "2026-09-30T15:00:00Z")
        provider.add(5, null, "2026-09-29T10:00:00Z")
        val photos = PhotoRepository(ApplicationProvider.getApplicationContext()).loadRecentPhotos(
            Instant.parse("2026-09-30T11:00:00Z"), ZoneId.of("Asia/Tokyo"),
        )
        assertEquals(listOf(3L, 5L, 2L), photos.map { android.content.ContentUris.parseId(it.uri) })
        assertEquals("uploaded", photos[1].capturedAtSource)
        assertEquals(Instant.parse("2026-09-29T10:00:00Z"), photos[1].capturedAt)
    }

    @Test
    fun `seven calendar days respect daylight saving transitions`() {
        provider.add(1, "2026-03-02T07:59:59Z")
        provider.add(2, "2026-03-02T08:00:00Z")
        provider.add(3, "2026-03-09T06:59:59Z")
        provider.add(4, "2026-03-09T07:00:00Z")
        val photos = PhotoRepository(ApplicationProvider.getApplicationContext()).loadRecentPhotos(
            Instant.parse("2026-03-08T20:00:00Z"), ZoneId.of("America/Los_Angeles"),
        )
        assertEquals(listOf(3L, 2L), photos.map { android.content.ContentUris.parseId(it.uri) })
    }
}

class TestPhotoProvider : ContentProvider() {
    lateinit var database: SQLiteDatabase
    var photoFile: java.io.File? = null
    override fun onCreate(): Boolean {
        database = SQLiteDatabase.create(null)
        database.execSQL("CREATE TABLE photos (_id INTEGER PRIMARY KEY, datetaken INTEGER, date_added INTEGER)")
        return true
    }
    fun add(id: Long, captured: String?, added: String = "2026-09-30T01:00:00Z") {
        database.insertOrThrow("photos", null, ContentValues().apply {
            put(MediaStore.Images.Media._ID, id)
            if (captured == null) putNull(MediaStore.Images.Media.DATE_TAKEN) else put(MediaStore.Images.Media.DATE_TAKEN, Instant.parse(captured).toEpochMilli())
            put(MediaStore.Images.Media.DATE_ADDED, Instant.parse(added).epochSecond)
        })
    }
    override fun query(uri: Uri, projection: Array<out String>?, selection: String?, selectionArgs: Array<out String>?, sortOrder: String?): Cursor =
        database.query("photos", projection, selection, selectionArgs, null, null, sortOrder)
    override fun getType(uri: Uri): String = "image/jpeg"
    override fun openFile(uri: Uri, mode: String): android.os.ParcelFileDescriptor =
        android.os.ParcelFileDescriptor.open(photoFile ?: throw java.io.FileNotFoundException(), android.os.ParcelFileDescriptor.MODE_READ_ONLY)
    override fun insert(uri: Uri, values: ContentValues?): Uri? = null
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = 0
    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?): Int = 0
}

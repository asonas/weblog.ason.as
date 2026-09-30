package com.asonas.weblog.photoinbox

import android.Manifest
import android.app.Application
import android.content.ContentUris
import android.graphics.Bitmap
import android.os.Looper
import android.provider.MediaStore
import android.widget.Button
import android.widget.TextView
import androidx.recyclerview.widget.GridLayoutManager
import androidx.recyclerview.widget.RecyclerView
import androidx.test.core.app.ApplicationProvider
import androidx.work.Configuration
import androidx.work.testing.SynchronousExecutor
import androidx.work.testing.WorkManagerTestInitHelper
import java.io.File
import java.time.Instant
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowAlertDialog
import org.robolectric.shadows.ShadowContentResolver

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28])
class MainActivityTest {
    private lateinit var application: Application
    private lateinit var provider: TestPhotoProvider
    private lateinit var item: UploadItem
    private lateinit var store: UploadQueueStore

    @Before
    fun setUp() = runBlocking {
        application = ApplicationProvider.getApplicationContext()
        File(application.filesDir, "PhotoInbox").deleteRecursively()
        application.getSharedPreferences("photo-selection", 0).edit().clear().commit()
        shadowOf(application).grantPermissions(Manifest.permission.READ_EXTERNAL_STORAGE)
        WorkManagerTestInitHelper.initializeTestWorkManager(application, Configuration.Builder().setExecutor(SynchronousExecutor()).build())
        provider = TestPhotoProvider()
        provider.onCreate()
        provider.add(1, Instant.now().toString())
        provider.photoFile = File(application.cacheDir, "test-photo.jpg").also { file ->
            file.outputStream().use { Bitmap.createBitmap(2, 2, Bitmap.Config.ARGB_8888).compress(Bitmap.CompressFormat.JPEG, 90, it) }
        }
        ShadowContentResolver.registerProviderInternal("media", provider)
        item = UploadItem(assetUri = ContentUris.withAppendedId(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, 1).toString(), capturedAt = Instant.now())
        store = UploadWorker.queueStore(application)
        store.enqueue(listOf(item))
        store.updateFailure(item.clientUploadId, UploadFailure("写真データの確認に失敗しました。", false, "invalid_sha256", requestId = "request-123"))
    }

    @After
    fun tearDown() { provider.database.close() }

    @Test
    fun `failed upload exposes reason and request id and can be manually retried`() {
        val controller = Robolectric.buildActivity(MainActivity::class.java).setup()
        try {
            val activity = controller.get()
            val failures = activity.findViewById<Button>(R.id.failureButton)
            until { failures.isEnabled }
            assertEquals("失敗 1件", failures.text.toString())
            assertEquals("送信済み 0件・待機 0件", activity.findViewById<TextView>(R.id.uploadStatus).text.toString())
            failures.performClick()
            shadowOf(ShadowAlertDialog.getLatestAlertDialog()).clickOnItem(0)
            val dialog = ShadowAlertDialog.getLatestAlertDialog()
            assertTrue(shadowOf(dialog).message.toString().contains("request-123"))
            assertTrue(shadowOf(dialog).message.toString().contains("写真データの確認"))
            dialog.getButton(android.app.AlertDialog.BUTTON_POSITIVE).performClick()
            until { runBlocking { store.items().single().failure == null } }
            assertNotEquals(item.clientUploadId, runBlocking { store.items().single().clientUploadId })
        } finally { controller.pause().stop().destroy() }
    }

    @Test
    @Config(qualifiers = "w800dp-h1000dp")
    fun `failed photo can be excluded and wide grids adapt with accessible photo state`() {
        val controller = Robolectric.buildActivity(MainActivity::class.java).setup().visible()
        try {
            val activity = controller.get()
            val failures = activity.findViewById<Button>(R.id.failureButton)
            until { failures.isEnabled }
            val grid = activity.findViewById<RecyclerView>(R.id.photoGrid)
            grid.measure(android.view.View.MeasureSpec.makeMeasureSpec(800, android.view.View.MeasureSpec.EXACTLY), android.view.View.MeasureSpec.makeMeasureSpec(600, android.view.View.MeasureSpec.EXACTLY))
            grid.layout(0, 0, 800, 600)
            shadowOf(Looper.getMainLooper()).idle()
            assertTrue((grid.layoutManager as GridLayoutManager).spanCount > 3)
            until { grid.childCount > 0 }
            assertTrue(kotlin.math.abs(grid.getChildAt(0).width - grid.getChildAt(0).height) <= 2)
            grid.measure(android.view.View.MeasureSpec.makeMeasureSpec(810, android.view.View.MeasureSpec.EXACTLY), android.view.View.MeasureSpec.makeMeasureSpec(600, android.view.View.MeasureSpec.EXACTLY))
            grid.layout(0, 0, 810, 600)
            shadowOf(Looper.getMainLooper()).idle()
            assertTrue(kotlin.math.abs(grid.getChildAt(0).width - grid.getChildAt(0).height) <= 2)
            assertTrue(grid.getChildAt(0).contentDescription.toString().contains("写真データの確認"))
            failures.performClick()
            shadowOf(ShadowAlertDialog.getLatestAlertDialog()).clickOnItem(0)
            ShadowAlertDialog.getLatestAlertDialog().getButton(android.app.AlertDialog.BUTTON_NEUTRAL).performClick()
            until { runBlocking { store.items().isEmpty() } }
            assertEquals(PhotoSelectionStatus.EXCLUDED, PhotoSelectionStore(application).apply { updatePhotos(listOf(LibraryPhoto(android.net.Uri.parse(item.assetUri), item.capturedAt, "photos"))) }.status(item.assetUri))
        } finally { controller.pause().stop().destroy() }
    }

    private fun until(check: () -> Boolean) {
        repeat(100) {
            shadowOf(Looper.getMainLooper()).idle()
            if (check()) return
            Thread.sleep(10)
        }
        fail("Timed out waiting for activity state")
    }

    @Test
    fun `queue updates do not reveal the photo grid without library permission`() {
        shadowOf(application).denyPermissions(Manifest.permission.READ_EXTERNAL_STORAGE)
        val controller = Robolectric.buildActivity(MainActivity::class.java).setup()
        try {
            shadowOf(Looper.getMainLooper()).idle()
            assertEquals(android.view.View.GONE, controller.get().findViewById<RecyclerView>(R.id.photoGrid).visibility)
            assertEquals("写真へのアクセスを許可してください", controller.get().findViewById<TextView>(R.id.emptyMessage).text.toString())
        } finally { controller.pause().stop().destroy() }
    }
}

package com.asonas.weblog.photoinbox

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import androidx.work.ListenableWorker
import androidx.work.testing.TestListenableWorkerBuilder
import java.io.File
import java.time.Instant
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28])
class UploadWorkerTest {
    @Test
    fun `worker leaves permanent failures untouched for manual action`() = runTest {
        val context = ApplicationProvider.getApplicationContext<Context>()
        File(context.filesDir, "PhotoInbox").deleteRecursively()
        val store = UploadWorker.queueStore(context)
        val item = UploadItem(assetUri = "content://media/external/images/media/1", capturedAt = Instant.parse("2026-09-30T01:00:00Z"))
        val failure = UploadFailure("不正なデータ", false, "invalid_upload_size")
        store.enqueue(listOf(item))
        store.updateFailure(item.clientUploadId, failure)
        val worker = TestListenableWorkerBuilder<UploadWorker>(context).build()
        assertEquals(ListenableWorker.Result.success(), worker.doWork())
        assertEquals(failure, store.items().single().failure)
        assertEquals(UploadStage.FAILED, store.items().single().stage)
    }
}

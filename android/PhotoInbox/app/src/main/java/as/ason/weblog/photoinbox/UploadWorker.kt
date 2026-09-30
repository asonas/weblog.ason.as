package com.asonas.weblog.photoinbox

import android.content.Context
import android.net.Uri
import android.graphics.BitmapFactory
import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters
import androidx.work.workDataOf
import kotlinx.coroutines.CancellationException
import java.io.File
import okhttp3.HttpUrl.Companion.toHttpUrl

class UploadWorker(context: Context, parameters: WorkerParameters) : CoroutineWorker(context, parameters) {
    override suspend fun doWork(): Result {
        val store = queueStore(applicationContext)
        val items = store.items().filter { it.shouldAttemptAutomatically }
        if (items.isEmpty()) return Result.success()
        val token = Credentials(applicationContext).loadToken() ?: return Result.failure()
        val api = MobileApiClient(API_BASE_URL.toHttpUrl(), token)
        var failed = false
        for (item in items) {
            try {
                process(item, store, api)
            } catch (error: Exception) {
                if (error is CancellationException) throw error
                val failure = UploadFailure.from(error)
                store.updateFailure(item.clientUploadId, failure)
                failed = failed || failure.automaticallyRetryable
            }
            setProgress(workDataOf("updated_at" to System.nanoTime()))
        }
        return if (failed) Result.retry() else Result.success()
    }

    private suspend fun process(
        original: UploadItem,
        store: UploadQueueStore,
        api: MobileApiClient,
    ) {
        if (original.stage == UploadStage.COMPLETING && original.uploadId != null) {
            api.complete(original.uploadId)
            finish(original, store, original.preparedFilePath?.let(::File))
            return
        }
        val prepared = restoredPhoto(original) ?: ImagePreparer(applicationContext).prepare(
            Uri.parse(original.assetUri),
            preparedDirectory(applicationContext),
            original.clientUploadId,
        ).also { photo ->
            store.update(
                original.copy(
                    preparedFilePath = photo.file.path,
                    contentType = photo.contentType,
                    size = photo.size,
                    sha256 = photo.sha256,
                    width = photo.width,
                    height = photo.height,
                ),
            )
        }
        val signed = api.createUpload(
            CreateUploadRequest(
                clientUploadId = original.clientUploadId,
                contentType = prepared.contentType,
                size = prepared.size,
                sha256 = prepared.sha256,
                capturedAt = original.capturedAt,
                capturedAtSource = original.capturedAtSource,
                width = prepared.width,
                height = prepared.height,
            ),
        )
        store.updateStage(original.clientUploadId, UploadStage.UPLOADING, signed.uploadId)
        MultipartUploader().upload(prepared.file, signed)
        store.updateStage(original.clientUploadId, UploadStage.COMPLETING, signed.uploadId)
        api.complete(signed.uploadId)
        finish(original, store, prepared.file)
    }

    private suspend fun finish(item: UploadItem, store: UploadQueueStore, preparedFile: File?) {
        PhotoSelectionStore(applicationContext).markUploaded(item.assetUri)
        preparedFile?.delete()
        store.remove(item.clientUploadId)
    }

    private fun restoredPhoto(item: UploadItem): PreparedPhoto? {
        val file = item.preparedFilePath?.let(::File) ?: return null
        if (!file.exists()) return null
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        if (item.width == null || item.height == null) BitmapFactory.decodeFile(file.path, bounds)
        return PreparedPhoto(
            file,
            item.contentType ?: return null,
            item.size ?: return null,
            item.sha256 ?: return null,
            item.width ?: bounds.outWidth.takeIf { it > 0 },
            item.height ?: bounds.outHeight.takeIf { it > 0 },
        )
    }

    companion object {
        const val UNIQUE_WORK_NAME = "photo-inbox-uploads"
        const val API_BASE_URL = "https://weblog.ason.as/"

        fun queueStore(context: Context) = UploadQueueStore(File(context.filesDir, "PhotoInbox/queue.json"))
        fun preparedDirectory(context: Context) = File(context.filesDir, "PhotoInbox/prepared")
    }
}

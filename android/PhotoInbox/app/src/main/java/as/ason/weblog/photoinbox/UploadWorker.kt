package com.asonas.weblog.photoinbox

import android.content.Context
import android.net.Uri
import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters
import java.io.File
import okhttp3.HttpUrl.Companion.toHttpUrl

class UploadWorker(context: Context, parameters: WorkerParameters) : CoroutineWorker(context, parameters) {
    override suspend fun doWork(): Result {
        val token = Credentials(applicationContext).loadToken() ?: return Result.failure()
        val store = queueStore(applicationContext)
        val api = MobileApiClient(API_BASE_URL.toHttpUrl(), token)
        var failed = false
        for (item in store.items()) {
            try {
                process(item, store, api)
            } catch (error: Exception) {
                store.updateStage(
                    item.clientUploadId,
                    UploadStage.FAILED,
                    uploadId = item.uploadId,
                    errorMessage = error.message ?: error.javaClass.simpleName,
                )
                failed = true
            }
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
        return PreparedPhoto(
            file,
            item.contentType ?: return null,
            item.size ?: return null,
            item.sha256 ?: return null,
        )
    }

    companion object {
        const val UNIQUE_WORK_NAME = "photo-inbox-uploads"
        const val API_BASE_URL = "https://weblog.ason.as/"

        fun queueStore(context: Context) = UploadQueueStore(File(context.filesDir, "PhotoInbox/queue.json"))
        fun preparedDirectory(context: Context) = File(context.filesDir, "PhotoInbox/prepared")
    }
}

package com.asonas.weblog.photoinbox

import java.io.File
import java.time.Instant
import java.util.UUID
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

enum class UploadStage {
    PENDING,
    UPLOADING,
    COMPLETING,
    FAILED,
}

data class UploadItem(
    val clientUploadId: UUID = UUID.randomUUID(),
    val assetUri: String,
    val capturedAt: Instant,
    val capturedAtSource: String = "photos",
    val stage: UploadStage = UploadStage.PENDING,
    val uploadId: String? = null,
    val errorMessage: String? = null,
    val preparedFilePath: String? = null,
    val contentType: String? = null,
    val size: Long? = null,
    val sha256: String? = null,
)

class UploadQueueStore(private val file: File) {
    private val mutex = Mutex()
    private var cached: List<UploadItem>? = null
    private val json = Json { prettyPrint = true }

    suspend fun items(): List<UploadItem> = mutex.withLock { load() }

    suspend fun enqueue(newItems: List<UploadItem>) = mutex.withLock {
        val current = load().toMutableList()
        val existing = current.mapTo(mutableSetOf()) { it.assetUri }
        current += newItems.filter { existing.add(it.assetUri) }
        save(current)
    }

    suspend fun update(item: UploadItem) = mutex.withLock {
        val current = load().toMutableList()
        val index = current.indexOfFirst { it.clientUploadId == item.clientUploadId }
        if (index >= 0) {
            current[index] = item
            save(current)
        }
    }

    suspend fun updateStage(
        id: UUID,
        stage: UploadStage,
        uploadId: String? = null,
        errorMessage: String? = null,
    ) = mutex.withLock {
        val current = load().toMutableList()
        val index = current.indexOfFirst { it.clientUploadId == id }
        if (index >= 0) {
            current[index] = current[index].copy(
                stage = stage,
                uploadId = uploadId,
                errorMessage = errorMessage,
            )
            save(current)
        }
    }

    suspend fun remove(id: UUID) = mutex.withLock {
        save(load().filterNot { it.clientUploadId == id })
    }

    private fun load(): List<UploadItem> {
        cached?.let { return it }
        if (!file.exists()) return emptyList<UploadItem>().also { cached = it }
        return json.decodeFromString<List<StoredUploadItem>>(file.readText())
            .map(StoredUploadItem::toUploadItem)
            .also { cached = it }
    }

    private fun save(items: List<UploadItem>) {
        file.parentFile?.mkdirs()
        val temporary = File(file.parentFile, "${file.name}.tmp")
        temporary.writeText(json.encodeToString(items.map(StoredUploadItem::from)))
        if (!temporary.renameTo(file)) {
            temporary.copyTo(file, overwrite = true)
            temporary.delete()
        }
        cached = items
    }
}

@Serializable
private data class StoredUploadItem(
    val clientUploadId: String,
    val assetUri: String,
    val capturedAt: String,
    val capturedAtSource: String,
    val stage: String,
    val uploadId: String? = null,
    val errorMessage: String? = null,
    val preparedFilePath: String? = null,
    val contentType: String? = null,
    val size: Long? = null,
    val sha256: String? = null,
) {
    fun toUploadItem() = UploadItem(
        clientUploadId = UUID.fromString(clientUploadId),
        assetUri = assetUri,
        capturedAt = Instant.parse(capturedAt),
        capturedAtSource = capturedAtSource,
        stage = UploadStage.valueOf(stage),
        uploadId = uploadId,
        errorMessage = errorMessage,
        preparedFilePath = preparedFilePath,
        contentType = contentType,
        size = size,
        sha256 = sha256,
    )

    companion object {
        fun from(item: UploadItem) = StoredUploadItem(
            clientUploadId = item.clientUploadId.toString(),
            assetUri = item.assetUri,
            capturedAt = item.capturedAt.toString(),
            capturedAtSource = item.capturedAtSource,
            stage = item.stage.name,
            uploadId = item.uploadId,
            errorMessage = item.errorMessage,
            preparedFilePath = item.preparedFilePath,
            contentType = item.contentType,
            size = item.size,
            sha256 = item.sha256,
        )
    }
}

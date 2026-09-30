package com.asonas.weblog.photoinbox

import android.util.AtomicFile
import java.io.File
import java.time.Instant
import java.util.UUID
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

@Serializable
data class LocalMemo(
    val id: String = UUID.randomUUID().toString(),
    val remoteId: String? = null,
    val body: String = "",
    val savedBody: String = "",
    val revision: Int = 0,
    val updatedAt: String = Instant.now().toString(),
    val flight: MemoOperation? = null,
) {
    val serverId get() = remoteId ?: id
    val needsSave get() = revision == 0 || body != savedBody
}

@Serializable
data class MemoOperation(val operationId: String = UUID.randomUUID().toString(), val expectedRevision: Int, val body: String, val deleting: Boolean = false)

@Serializable
data class MemoReceipt(val id: String, val revision: Int, val state: String, val result: String)

@Serializable
data class RemoteMemo(val id: String, val body: String, val revision: Int, @SerialName("updated_at") val updatedAt: String)

@Serializable
data class MemoListResponse(val memos: List<RemoteMemo>)

class MemoStore(file: File) {
    private val file = AtomicFile(file)
    private val mutex = Mutex()
    private val syncMutex = Mutex()
    private val values = MutableStateFlow<List<LocalMemo>>(emptyList())
    val memos = values.asStateFlow()
    var notice: String = ""
        private set
    private var loadFailure: Exception? = null

    init {
        try {
            if (this.file.baseFile.exists()) values.value = Json.decodeFromString(this.file.readFully().decodeToString())
        } catch (error: Exception) { loadFailure = error }
    }

    private suspend fun change(update: (List<LocalMemo>) -> List<LocalMemo>) = mutex.withLock {
        loadFailure?.let { throw it }
        val next = update(values.value)
        withContext(Dispatchers.IO) {
            file.baseFile.parentFile?.mkdirs()
            val output = file.startWrite()
            try { output.write(Json.encodeToString(next).toByteArray()); file.finishWrite(output) }
            catch (error: Exception) { file.failWrite(output); throw error }
        }
        values.value = next
    }

    suspend fun add(body: String = ""): String {
        val memo = LocalMemo(body = body)
        change { listOf(memo) + it }
        return memo.id
    }

    suspend fun edit(id: String, body: String, previousBody: String): String {
        var result = id
        change { rows ->
            val memo = rows.find { it.id == id }
            if (memo == null || memo.body != previousBody || memo.flight?.deleting == true) {
                val copy = LocalMemo(body = body)
                result = copy.id
                listOf(copy) + rows
            } else rows.map { if (it.id == id) it.copy(body = body, updatedAt = Instant.now().toString()) else it }
        }
        return result
    }

    suspend fun sync(api: MobileApiClient) {
        if (!syncMutex.tryLock()) return
        try {
            loadFailure?.let { throw it }
            for (item in values.value) {
                if (!item.needsSave && item.flight == null) continue
                require(item.body.toByteArray().size <= 512 * 1024) { "本文が512 KiBを超えています。端末には保存されています。" }
                val flight = item.flight ?: MemoOperation(expectedRevision = item.revision, body = item.body)
                change { rows -> rows.map { if (it.id == item.id) it.copy(flight = flight) else it } }
                val receipt = try { api.saveMemo(item.serverId, flight) }
                catch (error: MobileApiException) {
                    if (error.status == 409 && flight.deleting) change { rows -> rows.map { if (it.id == item.id) it.copy(flight = null) else it } }
                    throw error
                }
                change { rows ->
                    if (flight.deleting) rows.filterNot { it.id == item.id }
                    else rows.map { if (it.id == item.id) it.copy(remoteId = receipt.id, revision = receipt.revision, savedBody = flight.body, flight = null) else it }
                }
                if (receipt.result == "preserved_as_new") notice = "別の編集があったため、新しいメモとして保存しました。"
            }
            val remote = api.memos()
            change { rows ->
                val kept = rows.filter { it.needsSave || it.flight != null || remote.any { other -> other.id == it.serverId } }.map { memo ->
                    val match = remote.find { it.id == memo.serverId }
                    if (memo.needsSave || memo.flight != null || match == null) memo
                    else memo.copy(body = match.body, savedBody = match.body, revision = match.revision, updatedAt = match.updatedAt)
                }
                (kept + remote.filter { server -> kept.none { it.serverId == server.id } }.map { LocalMemo(id = it.id, body = it.body, savedBody = it.body, revision = it.revision, updatedAt = it.updatedAt) }).sortedByDescending { it.updatedAt }
            }
        } finally { syncMutex.unlock() }
    }

    suspend fun delete(id: String, api: MobileApiClient) {
        sync(api)
        change { rows -> rows.map {
            if (it.id != id) it else {
                check(!it.needsSave && it.flight == null) { "メモの保存を確認してから削除してください。" }
                it.copy(flight = MemoOperation(expectedRevision = it.revision, body = "", deleting = true))
            }
        } }
        sync(api)
    }
}

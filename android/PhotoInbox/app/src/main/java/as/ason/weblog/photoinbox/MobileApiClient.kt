package com.asonas.weblog.photoinbox

import java.io.File
import java.io.IOException
import java.time.Instant
import java.util.UUID
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.Serializable
import kotlinx.serialization.SerialName
import kotlinx.serialization.json.put
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.MultipartBody
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.asRequestBody
import okhttp3.RequestBody.Companion.toRequestBody

data class CreateUploadRequest(
    val clientUploadId: UUID,
    val contentType: String,
    val size: Long,
    val sha256: String,
    val capturedAt: Instant,
    val capturedAtSource: String,
    val width: Int? = null,
    val height: Int? = null,
)

data class SignedUpload(
    val uploadId: String,
    val uploadUrl: HttpUrl,
    val fields: Map<String, String>,
    val expiresAt: Instant,
)

data class PairedDevice(val token: String)

class MobileApiClient(
    private val baseUrl: HttpUrl,
    private val token: String?,
    private val http: OkHttpClient = OkHttpClient(),
) {
    suspend fun exchangePairing(code: String, deviceName: String): PairedDevice {
        val body = buildJsonObject {
            put("code", code.uppercase())
            put("device_name", deviceName)
        }
        val response = post("api/mobile/pairings/exchange", body.toString(), authenticated = false)
        return PairedDevice(Json.parseToJsonElement(response).jsonObject.getValue("token").jsonPrimitive.content)
    }

    suspend fun createUpload(payload: CreateUploadRequest): SignedUpload {
        val body = buildJsonObject {
            put("client_upload_id", payload.clientUploadId.toString())
            put("content_type", payload.contentType)
            put("size", payload.size)
            put("sha256", payload.sha256)
            put("captured_at", payload.capturedAt.toString())
            put("captured_at_source", payload.capturedAtSource)
            payload.width?.let { put("width", it) }
            payload.height?.let { put("height", it) }
        }
        val json = Json.parseToJsonElement(post("api/mobile/uploads", body.toString(), true)).jsonObject
        return SignedUpload(
            uploadId = json.getValue("upload_id").jsonPrimitive.content,
            uploadUrl = json.getValue("upload_url").jsonPrimitive.content.toHttpUrl(),
            fields = json.getValue("fields").jsonObject.mapValues { it.value.jsonPrimitive.content },
            expiresAt = Instant.parse(json.getValue("expires_at").jsonPrimitive.content),
        )
    }

    suspend fun complete(uploadId: String) {
        post("api/mobile/uploads/$uploadId/complete", "{}", true)
    }

    private suspend fun post(path: String, json: String, authenticated: Boolean): String =
        withContext(Dispatchers.IO) {
            val request = Request.Builder()
                .url(baseUrl.resolve(path) ?: throw MobileApiException("Invalid API path"))
                .post(json.toRequestBody(JSON_MEDIA_TYPE))
                .header("Accept", "application/json, application/problem+json")
                .apply {
                    if (authenticated) {
                        val value = token ?: throw MobileApiException("Device is not paired")
                        header("Authorization", "Bearer $value")
                    }
                }
                .build()
            http.newCall(request).execute().use { response ->
                val body = response.body?.string().orEmpty()
                if (!response.isSuccessful) {
                    val problem = runCatching { problemJson.decodeFromString<ProblemDetails>(body) }.getOrNull()
                    throw MobileApiException(problemMessage(problem?.code), response.code, problem)
                }
                body
            }
        }

    private companion object {
        val JSON_MEDIA_TYPE = "application/json".toMediaType()
        val problemJson = Json { ignoreUnknownKeys = true }
    }
}

class MultipartUploader(private val http: OkHttpClient = OkHttpClient()) {
    suspend fun upload(file: File, signed: SignedUpload) = withContext(Dispatchers.IO) {
        val body = MultipartBody.Builder().setType(MultipartBody.FORM).apply {
            signed.fields.toSortedMap().forEach { (name, value) -> addFormDataPart(name, value) }
            addFormDataPart(
                "file",
                "photo",
                file.asRequestBody((signed.fields["Content-Type"] ?: "application/octet-stream").toMediaType()),
            )
        }.build()
        val request = Request.Builder().url(signed.uploadUrl).post(body).build()
        http.newCall(request).execute().use { response ->
            if (!response.isSuccessful) throw UploadHttpException(response.code)
        }
    }
}

@Serializable
data class ProblemDetails(val code: String? = null, val field: String? = null, @SerialName("request_id") val requestId: String? = null)

private fun problemMessage(code: String?) = when (code) {
    "invalid_client_upload_id" -> "写真の送信情報が不正です。もう一度選び直してください。"
    "unsupported_content_type" -> "この写真形式には対応していません。"
    "invalid_upload_size" -> "写真のサイズ情報が不正です。もう一度選び直してください。"
    "invalid_sha256" -> "写真データの確認に失敗しました。もう一度選び直してください。"
    "invalid_captured_at_source" -> "写真の撮影日時情報が不正です。"
    "invalid_json_body", "invalid_content_type" -> "写真の送信情報を作成できませんでした。"
    else -> "写真を送信できませんでした。"
}

class MobileApiException(message: String, val status: Int? = null, val problem: ProblemDetails? = null) : Exception(message)
class UploadHttpException(val status: Int) : IOException("Upload returned $status")

package com.asonas.weblog.photoinbox

import java.io.IOException
import kotlinx.serialization.Serializable

@Serializable
data class UploadFailure(
    val message: String,
    val automaticallyRetryable: Boolean,
    val code: String? = null,
    val field: String? = null,
    val requestId: String? = null,
) {
    val requiresRepreparation: Boolean
        get() = code == "invalid_upload_size" || code == "invalid_sha256"

    companion object {
        fun from(error: Exception): UploadFailure = when (error) {
            is MobileApiException -> UploadFailure(
                message = error.message ?: "写真を送信できませんでした。",
                automaticallyRetryable = retryableStatus(error.status),
                code = error.problem?.code,
                field = error.problem?.field,
                requestId = error.problem?.requestId,
            )
            is UploadHttpException -> UploadFailure("写真データを送信できませんでした。", retryableStatus(error.status))
            is IOException -> UploadFailure("通信できませんでした。接続を確認してください。", true)
            else -> UploadFailure("写真を読み込むか変換することができませんでした。", false)
        }

        private fun retryableStatus(status: Int?) = status == 408 || status == 429 || (status != null && status >= 500)
    }
}

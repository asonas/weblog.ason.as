package com.asonas.weblog.photoinbox

import java.time.Instant
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

object PairingQr {
    fun code(value: String, now: Instant = Instant.now()): String {
        require(value.length <= 1024)
        val payload = Json.parseToJsonElement(value).jsonObject
        require(payload["type"]?.jsonPrimitive?.content == "weblog-photo-inbox-pairing")
        require(payload["version"]?.jsonPrimitive?.content == "1")
        require(payload["server"]?.jsonPrimitive?.content == "https://weblog.ason.as")
        val code = payload.getValue("code").jsonPrimitive.content
        require(Regex("[A-Z2-7]{12}").matches(code))
        require(Instant.parse(payload.getValue("expires_at").jsonPrimitive.content).isAfter(now))
        return code
    }
}

package harness.codegraff.android.auth

import org.json.JSONObject
import java.net.URI
import java.net.URLDecoder
import java.security.MessageDigest
import java.util.Base64
import java.util.UUID

/**
 * A CodeGraff sign-in that has started but not finished: the OAuth state and PKCE verifier the callback must match
 * (PendingSignIn.swift). It is stored, not held by a screen, because the browser can finish the sign-in after Android
 * has stopped the app, and the `harness://callback` link then starts it afresh.
 */
data class PendingSignIn(val state: String, val verifier: String, val startedAtMs: Long) {
    val challenge: String
        get() = Base64.getUrlEncoder().withoutPadding()
            .encodeToString(MessageDigest.getInstance("SHA-256").digest(verifier.toByteArray()))

    fun expired(nowMs: Long): Boolean = nowMs - startedAtMs > LIFETIME_MS

    sealed class CallbackError(message: String) : Exception(message) {
        class Denied(reason: String) : CallbackError("Sign-in was not completed ($reason).")
        class MissingCode : CallbackError("The sign-in link was missing its code. Try again.")
        class StateMismatch : CallbackError("That sign-in link belongs to a different attempt. Start sign-in again.")
        class Expired : CallbackError("That sign-in took too long. Start sign-in again.")
    }

    /** The authorization code from a `harness://callback` link, if it answers this sign-in. */
    fun code(callback: String, nowMs: Long): String {
        val query = query(callback)
        query["error"]?.let { throw CallbackError.Denied(query["error_description"] ?: it) }
        if (query["state"] != state) throw CallbackError.StateMismatch()
        if (expired(nowMs)) throw CallbackError.Expired()
        return query["code"]?.takeIf { it.isNotEmpty() } ?: throw CallbackError.MissingCode()
    }

    fun toJson(): String = JSONObject().put("state", state).put("verifier", verifier).put("startedAtMs", startedAtMs).toString()

    companion object {
        /** How long a started sign-in waits for its callback (a magic link can take a few minutes to arrive). */
        const val LIFETIME_MS = 30 * 60 * 1000L

        fun start(nowMs: Long): PendingSignIn {
            val verifier = UUID.randomUUID().toString().replace("-", "") + UUID.randomUUID().toString().replace("-", "")
            return PendingSignIn(UUID.randomUUID().toString(), verifier, nowMs)
        }

        fun fromJson(text: String): PendingSignIn? = runCatching {
            val json = JSONObject(text)
            PendingSignIn(json.getString("state"), json.getString("verifier"), json.getLong("startedAtMs"))
        }.getOrNull()

        fun isCallback(link: String): Boolean = runCatching {
            val uri = URI(link)
            uri.scheme == Endpoints.CALLBACK_SCHEME && uri.host == "callback"
        }.getOrDefault(false)

        private fun query(link: String): Map<String, String> {
            val raw = runCatching { URI(link).rawQuery }.getOrNull() ?: return emptyMap()
            return raw.split("&").filter { it.isNotEmpty() }.associate { pair ->
                val key = pair.substringBefore("=")
                val value = pair.substringAfter("=", "")
                URLDecoder.decode(key, "UTF-8") to URLDecoder.decode(value, "UTF-8")
            }
        }
    }
}

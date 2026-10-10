package harness.codegraff.android.auth

import harness.codegraff.android.model.AuthTokens
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import org.json.JSONObject
import java.util.Base64

/**
 * How a token refresh is judged and retried (TokenRefresh.swift). CodeGraff refresh tokens are single use, so one
 * distinction matters most:
 *  - the edge TURNED THE CREDENTIAL DOWN (400/401/403): it is spent or revoked, and the person signs in again;
 *  - the edge was UNREACHABLE or having a bad moment (offline, timeout, 5xx, 429): nothing was decided, and the same
 *    credential is kept and tried again.
 */
sealed interface RefreshOutcome {
    data class Refreshed(val tokens: AuthTokens) : RefreshOutcome
    data object Rejected : RefreshOutcome
    data object Unavailable : RefreshOutcome
}

object TokenRefresh {
    /** Waits between attempts of one round (up to three tries). The edge answers a repeated refresh the same way. */
    val retryDelaysMs = listOf(1_000L, 3_000L)

    fun classify(error: Throwable): RefreshOutcome =
        if (error is AuthHttpException && error.isRejection) RefreshOutcome.Rejected else RefreshOutcome.Unavailable

    /** One refresh round: retry [RefreshOutcome.Unavailable] after each delay, stop at the first definite answer. */
    suspend fun run(retryDelaysMs: List<Long> = TokenRefresh.retryDelaysMs, send: suspend () -> AuthTokens): RefreshOutcome {
        var attempt = 0
        while (true) {
            try {
                return RefreshOutcome.Refreshed(send())
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                val outcome = classify(e)
                if (outcome != RefreshOutcome.Unavailable || attempt >= retryDelaysMs.size) return outcome
                delay(retryDelaysMs[attempt])
                attempt += 1
            }
        }
    }

    /** The access token's `exp` in epoch seconds, or null when it can't be read (then it is refreshed). */
    fun expiry(accessToken: String): Long? = runCatching {
        val payload = accessToken.split(".")[1]
        val json = JSONObject(String(Base64.getUrlDecoder().decode(payload.padEnd((payload.length + 3) / 4 * 4, '='))))
        json.getLong("exp")
    }.getOrNull()

    /** Good for at least another minute, so a caller holding it never races its expiry. */
    fun fresh(accessToken: String, nowMs: Long): Boolean = expiry(accessToken)?.let { it * 1000 - nowMs > 60_000 } ?: false
}

package harness.codegraff.android.model

import org.json.JSONObject

// In-app account deletion: the edge's `POST /auth/account/delete` (AccountDeletion.swift). The edge
// checks with CodeGraff first, wipes the person's agent rooms, then has CodeGraff delete the account and
// purges its own copy. The wording and the token rules are shared with the SwiftUI app through
// apps/parity/vectors/account-deletion.json.

data class AuthTokens(val accessToken: String, val refreshToken: String)

sealed interface AccountDeletion {
    data object Deleted : AccountDeletion

    /**
     * The account is still there. [message] is what the person sees; [tokens] replace the stored pair, because the
     * edge spends the CodeGraff refresh token on the way and a device that kept the old one would be signed out.
     */
    data class Refused(val message: String, val tokens: AuthTokens?) : AccountDeletion

    companion object {
        fun from(status: Int, body: String): AccountDeletion {
            val json = runCatching { JSONObject(body) }.getOrNull()
            val deleted = json?.takeIf { it.has("deleted") && !it.isNull("deleted") }?.optBoolean("deleted")
            if (status in 200..299 && deleted == true) return Deleted
            return Refused(
                message(status, json?.optStringOrNull("error"), json?.optStringOrNull("message")),
                json?.optJSONObject("tokens")?.let { t ->
                    val access = t.optStringOrNull("accessToken")
                    val refresh = t.optStringOrNull("refreshToken")
                    if (access != null && refresh != null) AuthTokens(access, refresh) else null
                },
            )
        }

        private fun JSONObject.optStringOrNull(key: String): String? = if (has(key) && !isNull(key)) optString(key) else null

        private fun message(status: Int, error: String?, message: String?): String {
            // A blocker the person has to clear (a paid plan), in CodeGraff's words.
            if (status == 409) return message ?: "Your account can't be deleted yet."
            when (error) {
                "account_deletion_unavailable" -> return "Account deletion isn't available yet. Nothing was deleted."
                "rooms_unavailable" -> return "Couldn't reach your agent rooms, so nothing was deleted. Try again in a moment."
                "wrong_account" -> return "This sign-in belongs to a different account. Sign out, sign back in, then try again."
                "codegraff_unavailable" -> return "Couldn't reach CodeGraff, so your account wasn't deleted. Try again in a moment."
            }
            if (status == 401) return "Your sign-in has expired. Sign out, sign back in, then try again."
            return "Couldn't delete your account (HTTP $status). Try again in a moment."
        }
    }
}

/** What the model needs from the account backend; the live client provides it, tests fake it. */
interface AccountApi {
    suspend fun currentTokens(): AuthTokens?
    suspend fun delete(tokens: AuthTokens): AccountDeletion
    fun storeTokens(tokens: AuthTokens)
}

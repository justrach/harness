package harness.codegraff.android.auth

import java.net.URLEncoder

/** Production cloud endpoints, the same as the iOS `Endpoints` (mirrors edge/wrangler.jsonc). */
object Endpoints {
    const val EDGE_URL = "https://edge.codegraff.com"
    const val CODEGRAFF_CLIENT_ID = "cg_client_43e753878956c2cf7b5b0f53"
    const val CODEGRAFF_API_BASE = "https://codegraff.com"
    const val CALLBACK_SCHEME = "harness"

    /**
     * The edge's app callback, registered with CodeGraff. It forwards the code to `harness://callback`, which this
     * app handles exactly as the iOS app does, so both share one registered redirect.
     */
    const val REDIRECT_URI = "https://edge.codegraff.com/auth/ios/callback"

    fun authorizeUrl(state: String, challenge: String): String {
        val query = listOf(
            "response_type" to "code",
            "client_id" to CODEGRAFF_CLIENT_ID,
            "redirect_uri" to REDIRECT_URI,
            "scope" to "openid email offline_access",
            "state" to state,
            "nonce" to state,
            "code_challenge" to challenge,
            "code_challenge_method" to "S256",
        ).joinToString("&") { (key, value) -> "$key=${URLEncoder.encode(value, "UTF-8").replace("+", "%20")}" }
        return "$CODEGRAFF_API_BASE/oauth/authorize?$query"
    }
}

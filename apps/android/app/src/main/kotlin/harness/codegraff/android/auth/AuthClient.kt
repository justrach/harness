package harness.codegraff.android.auth

import harness.codegraff.android.model.AccountDeletion
import harness.codegraff.android.model.AuthTokens
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

data class AuthUser(val id: String, val email: String?)

data class AuthOrg(val id: String, val organizationId: String, val name: String)

/** The edge answered with a non-2xx status. */
class AuthHttpException(val status: Int, val body: String) : Exception("Auth failed ($status): $body") {
    /** The edge refused the credential itself, as opposed to failing to answer. */
    val isRejection: Boolean get() = status == 400 || status == 401 || status == 403
}

/** The edge's CodeGraff OAuth routes: exchange, refresh, the personal workspace, deletion. */
interface AuthApi {
    suspend fun exchange(code: String, codeVerifier: String, redirectUri: String, nonce: String): Pair<AuthUser, AuthTokens>
    suspend fun refresh(refreshToken: String, organizationId: String? = null): AuthTokens
    suspend fun orgs(accessToken: String): List<AuthOrg>
    suspend fun deleteAccount(tokens: AuthTokens): AccountDeletion
}

/** [AuthApi] over HTTPS (AuthClient.swift). */
class AuthClient(private val baseUrl: String) : AuthApi {
    override suspend fun exchange(code: String, codeVerifier: String, redirectUri: String, nonce: String): Pair<AuthUser, AuthTokens> {
        val json = post(
            "auth/exchange",
            JSONObject().put("code", code).put("codeVerifier", codeVerifier).put("redirectUri", redirectUri).put("nonce", nonce),
        )
        val user = json.getJSONObject("user")
        return AuthUser(user.getString("id"), user.optString("email").ifEmpty { null }) to tokens(json)
    }

    override suspend fun refresh(refreshToken: String, organizationId: String?): AuthTokens {
        val body = JSONObject().put("refreshToken", refreshToken)
        organizationId?.let { body.put("organizationId", it) }
        return tokens(post("auth/refresh", body))
    }

    override suspend fun orgs(accessToken: String): List<AuthOrg> = withContext(Dispatchers.IO) {
        val conn = open("auth/orgs", "GET")
        conn.setRequestProperty("Authorization", "Bearer $accessToken")
        val orgs = JSONObject(read(conn)).getJSONArray("orgs")
        (0 until orgs.length()).map { i ->
            val org = orgs.getJSONObject(i)
            AuthOrg(org.getString("id"), org.getString("organizationId"), org.getString("name"))
        }
    }

    /** Both halves of the sign-in go along: the edge refuses a delete unless they belong to the same person. */
    override suspend fun deleteAccount(tokens: AuthTokens): AccountDeletion = withContext(Dispatchers.IO) {
        val conn = open("auth/account/delete", "POST")
        conn.setRequestProperty("Authorization", "Bearer ${tokens.accessToken}")
        send(conn, JSONObject().put("refreshToken", tokens.refreshToken).put("confirm", "delete"))
        val status = conn.responseCode
        val body = (if (status in 200..299) conn.inputStream else conn.errorStream)?.bufferedReader()?.use { it.readText() }.orEmpty()
        AccountDeletion.from(status, body)
    }

    private fun tokens(json: JSONObject) = AuthTokens(json.getString("accessToken"), json.getString("refreshToken"))

    private suspend fun post(path: String, body: JSONObject): JSONObject = withContext(Dispatchers.IO) {
        val conn = open(path, "POST")
        send(conn, body)
        JSONObject(read(conn))
    }

    private fun open(path: String, method: String): HttpURLConnection =
        (URL("${baseUrl.trimEnd('/')}/$path").openConnection() as HttpURLConnection).apply {
            requestMethod = method
            connectTimeout = 15_000
            readTimeout = 30_000
        }

    private fun send(conn: HttpURLConnection, body: JSONObject) {
        conn.doOutput = true
        conn.setRequestProperty("Content-Type", "application/json")
        conn.outputStream.use { it.write(body.toString().toByteArray()) }
    }

    private fun read(conn: HttpURLConnection): String {
        val status = conn.responseCode
        if (status !in 200..299) {
            throw AuthHttpException(status, conn.errorStream?.bufferedReader()?.use { it.readText() }.orEmpty())
        }
        return conn.inputStream.bufferedReader().use { it.readText() }
    }
}

package harness.codegraff.android

import harness.codegraff.android.auth.AuthApi
import harness.codegraff.android.auth.AuthHttpException
import harness.codegraff.android.auth.AuthOrg
import harness.codegraff.android.auth.AuthUser
import harness.codegraff.android.auth.CodegraffAccount
import harness.codegraff.android.auth.Endpoints
import harness.codegraff.android.auth.Identity
import harness.codegraff.android.auth.MemorySecretStore
import harness.codegraff.android.auth.PendingSignIn
import harness.codegraff.android.auth.RefreshOutcome
import harness.codegraff.android.auth.SignInResult
import harness.codegraff.android.auth.TokenRefresh
import harness.codegraff.android.model.AccountDeletion
import harness.codegraff.android.model.AuthTokens
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.net.URLDecoder
import java.util.Base64

class AuthTest {
    @Test
    fun theChallengeIsS256OfTheVerifier() {
        // RFC 7636, appendix B.
        val pending = PendingSignIn("s", "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk", 0)
        assertEquals("E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", pending.challenge)
    }

    @Test
    fun theAuthorizeUrlCarriesTheSharedRedirectAndPkce() {
        val url = Endpoints.authorizeUrl("st", "ch")
        assertTrue(url.startsWith("https://codegraff.com/oauth/authorize?"))
        val query = url.substringAfter("?").split("&").associate {
            it.substringBefore("=") to URLDecoder.decode(it.substringAfter("="), "UTF-8")
        }
        assertEquals("https://edge.codegraff.com/auth/ios/callback", query["redirect_uri"])
        assertEquals("openid email offline_access", query["scope"])
        assertEquals("S256", query["code_challenge_method"])
        assertEquals("ch", query["code_challenge"])
        assertEquals("st", query["state"])
        assertEquals("st", query["nonce"])
        assertFalse("spaces are %20, not +", url.contains("+"))
    }

    @Test
    fun aCallbackAnswersOnlyItsOwnSignIn() {
        val pending = PendingSignIn("st4te", "v", startedAtMs = 1_000)
        assertEquals("abc", pending.code("harness://callback?code=abc&state=st4te", nowMs = 2_000))
        assertError<PendingSignIn.CallbackError.StateMismatch> { pending.code("harness://callback?code=abc&state=other", 2_000) }
        assertError<PendingSignIn.CallbackError.MissingCode> { pending.code("harness://callback?state=st4te", 2_000) }
        assertError<PendingSignIn.CallbackError.Expired> {
            pending.code("harness://callback?code=abc&state=st4te", 1_000 + PendingSignIn.LIFETIME_MS + 1)
        }
        val denied = assertError<PendingSignIn.CallbackError.Denied> {
            pending.code("harness://callback?error=access_denied&error_description=Not%20now", 2_000)
        }
        assertEquals("Sign-in was not completed (Not now).", denied.message)
        assertTrue(PendingSignIn.isCallback("harness://callback?code=a"))
        assertFalse(PendingSignIn.isCallback("harness://other?code=a"))
        assertFalse(PendingSignIn.isCallback("https://callback?code=a"))
        assertEquals(pending, PendingSignIn.fromJson(pending.toJson()))
    }

    @Test
    fun aRefusedCredentialIsFinalAndAnUnreachableEdgeIsRetried() = runBlocking {
        assertEquals(RefreshOutcome.Rejected, TokenRefresh.classify(AuthHttpException(401, "")))
        assertEquals(RefreshOutcome.Unavailable, TokenRefresh.classify(AuthHttpException(503, "")))
        assertEquals(RefreshOutcome.Unavailable, TokenRefresh.classify(java.io.IOException("offline")))

        var tries = 0
        assertEquals(RefreshOutcome.Rejected, TokenRefresh.run(listOf(0, 0)) { tries++; throw AuthHttpException(400, "") })
        assertEquals(1, tries)

        tries = 0
        assertEquals(RefreshOutcome.Unavailable, TokenRefresh.run(listOf(0, 0)) { tries++; throw AuthHttpException(503, "") })
        assertEquals(3, tries)

        tries = 0
        val ok = AuthTokens("a", "r")
        assertEquals(RefreshOutcome.Refreshed(ok), TokenRefresh.run(listOf(0, 0)) { if (tries++ == 0) throw java.io.IOException() else ok })
    }

    @Test
    fun anAccessTokenIsFreshForMoreThanAMinute() {
        val now = 1_000_000_000L
        assertTrue(TokenRefresh.fresh(jwt(now / 1000 + 120), now))
        assertFalse(TokenRefresh.fresh(jwt(now / 1000 + 30), now))
        assertFalse(TokenRefresh.fresh("not-a-jwt", now))
    }

    // MARK: the account against a stand-in edge

    /** The edge's answers, recorded. */
    private class FakeEdge(private val orgs: List<Pair<String, String>>) : AuthApi {
        var refreshes = 0
        var refreshStatus = 200
        var lastRefreshOrg: String? = null

        override suspend fun exchange(code: String, codeVerifier: String, redirectUri: String, nonce: String): Pair<AuthUser, AuthTokens> {
            check(code == "abc" && redirectUri == Endpoints.REDIRECT_URI && codeVerifier.length == 64)
            return AuthUser("u1", null) to AuthTokens(jwt(9_999_999_999), "r0")
        }

        override suspend fun refresh(refreshToken: String, organizationId: String?): AuthTokens {
            lastRefreshOrg = organizationId
            refreshes += 1
            if (refreshStatus != 200) throw AuthHttpException(refreshStatus, "no")
            return AuthTokens(jwt(9_999_999_999, "a$refreshes"), "r$refreshes")
        }

        override suspend fun orgs(accessToken: String): List<AuthOrg> = orgs.map { (id, name) -> AuthOrg("row-$id", id, name) }

        override suspend fun deleteAccount(tokens: AuthTokens): AccountDeletion = AccountDeletion.Deleted
    }

    private var edge = FakeEdge(emptyList())

    private fun startEdge(orgs: List<Pair<String, String>>) {
        edge = FakeEdge(orgs)
    }

    private val refreshes get() = edge.refreshes
    private val lastRefreshOrg get() = edge.lastRefreshOrg

    private fun account(store: MemorySecretStore = MemorySecretStore(), now: () -> Long = { 1_000L }): CodegraffAccount =
        CodegraffAccount(store, "https://edge.test", edge, now)

    @Test
    fun signingInScopesToTheOnlyWorkspaceAndKeepsTheSignIn() = runBlocking {
        startEdge(listOf("org1" to "Personal"))
        val store = MemorySecretStore()
        val account = account(store)
        val page = account.startSignIn()
        val state = URLDecoder.decode(page.substringAfter("state=").substringBefore("&"), "UTF-8")
        val result = account.finishSignIn("harness://callback?code=abc&state=$state")
        assertEquals(SignInResult.SignedIn(Identity("u1", "org1")), result)
        assertEquals("org1", lastRefreshOrg)
        // Stored: a new process is signed in as the same identity.
        assertEquals(Identity("u1", "org1"), account(store).identity)
        // One use: the same link again finds no sign-in waiting.
        try {
            account.finishSignIn("harness://callback?code=abc&state=$state")
            fail("a used sign-in finished twice")
        } catch (_: IllegalStateException) {
        }
    }

    @Test
    fun severalWorkspacesWaitForAPick() = runBlocking {
        startEdge(listOf("org1" to "Personal", "org2" to "Team"))
        val account = account()
        val state = URLDecoder.decode(account.startSignIn().substringAfter("state=").substringBefore("&"), "UTF-8")
        val pick = account.finishSignIn("harness://callback?code=abc&state=$state") as SignInResult.PickOrg
        assertEquals(listOf("Personal", "Team"), pick.orgs.map { it.name })
        assertNull("not signed in until a workspace is picked", account.identity)
        assertEquals(Identity("u1", "org2"), account.selectOrg(pick.userId, pick.tokens, pick.orgs[1]))
    }

    @Test
    fun anExpiredTokenIsRefreshedOnceAndARefusalSignsOut() {
        startEdge(listOf("org1" to "Personal"))
        val store = MemorySecretStore()
        var now = 1_000L
        val account = account(store) { now }
        account.storeTokens(AuthTokens(jwt(10), "r0"))
        store.put("codegraffUserId", "u1")
        store.put("codegraffOrgId", "org1")

        val fresh = account.bearer()!!
        assertEquals(1, refreshes)
        assertEquals("org1", lastRefreshOrg)
        assertEquals(fresh, account.bearer())
        assertEquals("a fresh token is not refreshed again", 1, refreshes)

        // The edge turns the credential down: no token, one notice, and nothing sent with it again.
        account.storeTokens(AuthTokens(jwt(10), "spent"))
        edge.refreshStatus = 401
        var rejected = 0
        account.onRejected = { rejected++ }
        assertNull(account.bearer())
        assertNull(account.bearer())
        assertEquals(1, rejected)
        assertEquals(2, refreshes)
    }

    private companion object {
        fun jwt(exp: Long, id: String = "a"): String {
            val enc = Base64.getUrlEncoder().withoutPadding()
            val header = enc.encodeToString("""{"alg":"none"}""".toByteArray())
            val payload = enc.encodeToString("""{"exp":$exp,"jti":"$id"}""".toByteArray())
            return "$header.$payload.sig"
        }
    }

    private inline fun <reified T : Throwable> assertError(block: () -> Unit): T {
        try {
            block()
        } catch (e: Throwable) {
            if (e is T) return e
            throw AssertionError("expected ${T::class.simpleName}, got $e", e)
        }
        throw AssertionError("expected ${T::class.simpleName}")
    }
}

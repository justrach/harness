package harness.codegraff.android.auth

import harness.codegraff.android.model.AccountApi
import harness.codegraff.android.model.AccountDeletion
import harness.codegraff.android.model.AuthTokens
import kotlinx.coroutines.runBlocking

/** Who the phone is signed in as, and to which workspace. */
data class Identity(val userId: String, val orgId: String)

/** What finishing a sign-in leads to. */
sealed interface SignInResult {
    data class SignedIn(val identity: Identity) : SignInResult

    /** More than one workspace: the person picks, then [CodegraffAccount.selectOrg]. */
    data class PickOrg(val userId: String, val tokens: AuthTokens, val orgs: List<AuthOrg>) : SignInResult
}

/**
 * The CodeGraff sign-in (AppModel's sign-in flow and AppConfig's token handling on iOS): starts and finishes the PKCE
 * browser sign-in, stores the pair, and serves a fresh access token to the native core.
 */
class CodegraffAccount(
    private val store: SecretStore,
    val edgeUrl: String = Endpoints.EDGE_URL,
    private val client: AuthApi = AuthClient(edgeUrl),
    private val clock: () -> Long = System::currentTimeMillis,
) : AccountApi {
    private val lock = Any()
    private val refreshLock = Any()
    private var tokens: AuthTokens? = loadTokens()

    /** The refresh token the edge turned down; nothing is sent with it again until a new sign-in. */
    private var rejectedRefresh: String? = null

    /** Called (on the refreshing thread) when the edge refuses the stored sign-in: the person must sign in again. */
    @Volatile
    var onRejected: (() -> Unit)? = null

    /** The signed-in identity, or null when the phone is signed out. */
    val identity: Identity?
        get() {
            if (synchronized(lock) { tokens } == null) return null
            val user = store.get(USER) ?: return null
            val org = store.get(ORG) ?: return null
            return Identity(user, org)
        }

    // MARK: sign-in

    /** Begin a browser sign-in: remembers its state and verifier, and returns the page to open. */
    fun startSignIn(): String {
        val pending = PendingSignIn.start(clock())
        store.put(PENDING, pending.toJson())
        return Endpoints.authorizeUrl(pending.state, pending.challenge)
    }

    /**
     * Finish a sign-in from its `harness://callback` link. A link for another attempt leaves this one waiting (its
     * error says so); any other answer uses the pending sign-in up.
     */
    suspend fun finishSignIn(callback: String): SignInResult {
        val pending = store.get(PENDING)?.let(PendingSignIn::fromJson)
            ?: throw IllegalStateException("No sign-in is waiting. Start sign-in again.")
        val code = try {
            pending.code(callback, clock())
        } catch (e: PendingSignIn.CallbackError.StateMismatch) {
            throw e
        } catch (e: PendingSignIn.CallbackError) {
            store.remove(PENDING)
            throw e
        }
        store.remove(PENDING)
        val (user, first) = client.exchange(code, pending.verifier, Endpoints.REDIRECT_URI, pending.state)
        val orgs = client.orgs(first.accessToken)
        return when {
            orgs.isEmpty() -> throw AuthHttpException(403, "No organizations for this account")
            orgs.size == 1 -> SignInResult.SignedIn(selectOrg(user.id, first, orgs.single()))
            else -> SignInResult.PickOrg(user.id, first, orgs)
        }
    }

    /** Scope the sign-in to [org] (adds the org claim) and store it. */
    suspend fun selectOrg(userId: String, tokens: AuthTokens, org: AuthOrg): Identity {
        val scoped = client.refresh(tokens.refreshToken, org.organizationId)
        store.put(USER, userId)
        store.put(ORG, org.organizationId)
        storeTokens(scoped)
        synchronized(lock) { rejectedRefresh = null }
        return Identity(userId, org.organizationId)
    }

    fun signOut() {
        synchronized(lock) {
            tokens = null
            rejectedRefresh = null
        }
        // The refresh token first: it is the half that cannot be replaced.
        store.remove(REFRESH)
        store.remove(ACCESS)
        store.remove(USER)
        store.remove(ORG)
        store.remove(PENDING)
    }

    // MARK: tokens

    /**
     * An access token good for at least another minute, refreshing first when needed. The native core calls this on
     * its own threads; one refresh runs at a time and later callers take its result. Null means there is no usable
     * sign-in.
     */
    fun bearer(): String? {
        val current = synchronized(lock) { tokens } ?: return null
        if (TokenRefresh.fresh(current.accessToken, clock())) return current.accessToken
        return synchronized(refreshLock) {
            val latest = synchronized(lock) { tokens } ?: return@synchronized null
            if (latest != current && TokenRefresh.fresh(latest.accessToken, clock())) return@synchronized latest.accessToken
            if (synchronized(lock) { rejectedRefresh } == latest.refreshToken) return@synchronized null
            val org = store.get(ORG)
            when (val outcome = runBlocking { TokenRefresh.run { client.refresh(latest.refreshToken, org) } }) {
                is RefreshOutcome.Refreshed -> {
                    storeTokens(outcome.tokens)
                    outcome.tokens.accessToken
                }
                RefreshOutcome.Rejected -> {
                    synchronized(lock) { rejectedRefresh = latest.refreshToken }
                    onRejected?.invoke()
                    null
                }
                // Undecided, not refused: the server answers the old token and the core's backoff retries.
                RefreshOutcome.Unavailable -> latest.accessToken
            }
        }
    }

    override suspend fun currentTokens(): AuthTokens? {
        bearer() ?: return null
        return synchronized(lock) { tokens }
    }

    override suspend fun delete(tokens: AuthTokens): AccountDeletion = client.deleteAccount(tokens)

    override fun storeTokens(tokens: AuthTokens) {
        store.put(REFRESH, tokens.refreshToken)
        store.put(ACCESS, tokens.accessToken)
        synchronized(lock) { this.tokens = tokens }
    }

    private fun loadTokens(): AuthTokens? {
        val refresh = store.get(REFRESH) ?: return null
        return AuthTokens(store.get(ACCESS).orEmpty(), refresh)
    }

    private companion object {
        const val ACCESS = "codegraffAccessToken"
        const val REFRESH = "codegraffRefreshToken"
        const val USER = "codegraffUserId"
        const val ORG = "codegraffOrgId"
        const val PENDING = "pendingSignIn"
    }
}

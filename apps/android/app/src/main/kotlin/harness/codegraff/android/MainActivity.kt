package harness.codegraff.android

import android.content.Intent
import android.content.pm.ApplicationInfo
import android.net.Uri
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.lifecycleScope
import harness.codegraff.android.auth.AuthOrg
import harness.codegraff.android.auth.CodegraffAccount
import harness.codegraff.android.auth.Endpoints
import harness.codegraff.android.auth.Identity
import harness.codegraff.android.auth.KeystoreSecretStore
import harness.codegraff.android.auth.PendingSignIn
import harness.codegraff.android.auth.SignInResult
import harness.codegraff.android.model.AuthTokens
import harness.codegraff.android.perf.Perf
import harness.codegraff.android.perf.PerfSharing
import harness.codegraff.android.sync.LiveConnection
import harness.codegraff.android.sync.LiveSync
import harness.codegraff.android.theme.HarnessTheme
import harness.codegraff.android.theme.rememberThemeStore
import harness.codegraff.android.ui.HarnessApp
import harness.codegraff.android.ui.signin.SignInScreen
import harness.codegraff.android.ui.signin.SignInUi
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch
import java.io.File

class MainActivity : ComponentActivity() {
    private lateinit var account: CodegraffAccount

    /** Which [AppModel] is current: a sign-in or sign-out starts a new one (demo and live never share a model). */
    private var generation by mutableIntStateOf(0)

    /** The sign-in gate is up. */
    private var gate by mutableStateOf(false)
    private var signIn by mutableStateOf(SignInUi())

    /** A sign-in with several workspaces waits here for the pick. */
    private var picking: Pair<String, AuthTokens>? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        account = CodegraffAccount(KeystoreSecretStore(applicationContext))
        account.onRejected = { runOnUiThread { sessionExpired() } }
        AppModel.scenario = intent?.getStringExtra("scenario")
        if (savedInstanceState != null) {
            generation = savedInstanceState.getInt(GENERATION)
            gate = savedInstanceState.getBoolean(GATE)
        } else {
            gate = decideLaunch()
        }
        // A restored model kept its sync; a new one opens with the identity stored now.
        armFactories()
        PerfSharing.init(this)
        // Only a launch counts as startup; a rotation or a return to the app is not one.
        if (Perf.isColdStart()) Perf.watchFirstFrame(this)
        setContent {
            val themeStore = rememberThemeStore()
            HarnessTheme(themeStore) {
                if (gate) {
                    SignInScreen(
                        ui = signIn,
                        onSignIn = ::startSignIn,
                        onPickOrg = ::pickOrg,
                        onDemo = ::exploreDemo,
                    )
                } else {
                    val model = remember(generation) { model() }
                    HarnessApp(model = model, onSignOut = ::signOut)
                }
            }
        }
        handleCallback(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleCallback(intent)
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        outState.putInt(GENERATION, generation)
        outState.putBoolean(GATE, gate)
    }

    override fun onResume() {
        super.onResume()
        Perf.resume(this)
        if (!gate) model().foregrounded()
    }

    override fun onPause() {
        if (!gate) model().backgrounded()
        Perf.pause(this)
        PerfSharing.flush(this)
        super.onPause()
    }

    private fun model(): AppModel = ViewModelProvider(this)["app-$generation", AppModel::class.java]

    /**
     * What a fresh launch shows: a debug rig (a dev edge or a demo scenario) goes straight in, a stored CodeGraff
     * sign-in goes live, and otherwise the sign-in gate. Returns whether the gate is up.
     */
    private fun decideLaunch(): Boolean = devEdge() == null && AppModel.scenario == null && account.identity == null

    /** Point the next new model at the live sync for the current identity, or at the demo. */
    private fun armFactories() {
        val dev = devEdge()
        val identity = account.identity
        when {
            dev != null -> {
                AppModel.liveFactory = { LiveSync.open(applicationContext, dev) }
                AppModel.accountFactory = null
            }
            identity != null -> {
                AppModel.liveFactory = { LiveSync.open(applicationContext, connection(identity)) }
                AppModel.accountFactory = { account }
            }
            else -> {
                AppModel.liveFactory = null
                AppModel.accountFactory = null
            }
        }
    }

    private fun connection(identity: Identity) =
        LiveConnection(Endpoints.EDGE_URL, identity.userId, identity.orgId) { account.bearer() }

    // MARK: sign-in

    private fun startSignIn() {
        signIn = SignInUi(busy = true)
        val page = account.startSignIn()
        runCatching { startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(page))) }
            .onFailure { signIn = SignInUi(error = "No browser is available to sign in with.") }
    }

    /** A `harness://callback` link from the browser: only the pending sign-in's own link is accepted, and only once. */
    private fun handleCallback(intent: Intent?) {
        val link = intent?.data?.toString() ?: return
        if (!PendingSignIn.isCallback(link)) return
        intent.data = null
        signIn = SignInUi(busy = true)
        lifecycleScope.launch {
            signIn = try {
                when (val result = account.finishSignIn(link)) {
                    is SignInResult.SignedIn -> {
                        goLive()
                        SignInUi()
                    }
                    is SignInResult.PickOrg -> {
                        picking = result.userId to result.tokens
                        SignInUi(orgs = result.orgs)
                    }
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: PendingSignIn.CallbackError) {
                SignInUi(error = e.message)
            } catch (e: Exception) {
                SignInUi(error = "Couldn't finish signing in. Check your connection and try again.")
            }
        }
    }

    private fun pickOrg(org: AuthOrg) {
        val (userId, tokens) = picking ?: return
        signIn = signIn.copy(busy = true, error = null)
        lifecycleScope.launch {
            signIn = try {
                account.selectOrg(userId, tokens, org)
                picking = null
                goLive()
                SignInUi()
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                signIn.copy(busy = false, error = "Couldn't open that workspace. Try again.")
            }
        }
    }

    private fun goLive() {
        retireModel()
        armFactories()
        generation += 1
        gate = false
    }

    private fun exploreDemo() {
        retireModel()
        AppModel.liveFactory = null
        AppModel.accountFactory = null
        generation += 1
        signIn = SignInUi()
        gate = false
    }

    /** Sign out from Settings (or after an account is deleted): the account's local data goes with it. */
    private fun signOut() {
        retireModel()
        val identity = account.identity
        account.signOut()
        if (identity != null) File(filesDir, "sync").deleteRecursively()
        armFactories()
        generation += 1
        signIn = SignInUi()
        gate = true
    }

    /** The edge refused the stored sign-in: back to the gate, keeping the cached docs for the same person. */
    private fun sessionExpired() {
        if (gate) return
        retireModel()
        account.signOut()
        armFactories()
        generation += 1
        signIn = SignInUi(error = "Your sign-in expired. Sign in again.")
        gate = true
    }

    /** Stop the current model's sync before a new model replaces it. */
    private fun retireModel() {
        if (!gate) model().live?.core?.stop()
    }

    /**
     * Debug rig for a dev-mode edge (`AUTH_MODE=dev`), the counterpart of the iOS launch arguments `-setedge`,
     * `-setmode dev`, `-setuser` and `-setorg`:
     * `adb shell am start -n harness.codegraff.android/.MainActivity --es edge http://10.0.2.2:27640 --es user u1 --es org o1`.
     * Only debuggable builds read it.
     */
    private fun devEdge(): LiveConnection? {
        if (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE == 0) return null
        val extras = intent?.extras ?: return null
        val edge = extras.getString("edge") ?: return null
        val user = extras.getString("user") ?: return null
        return LiveConnection.dev(edge, user, extras.getString("org").orEmpty())
    }

    private companion object {
        const val GENERATION = "generation"
        const val GATE = "gate"
    }
}
